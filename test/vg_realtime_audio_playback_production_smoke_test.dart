// vg_realtime_audio_playback_production_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK (Y8a) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-DEAD-OBJECT (Y8b) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SEEK (Y9) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-REPEATED-SEEK (Y10b) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-FOCUS-RESPONSE (Y11b): Android True-DAG Phase 4
// realtime audio playback production sink, clock, dead-object, forward-seek, repeated-seek, and focus response diagnostic smoke foundation
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'production_engine_component_diagnostic_route_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_sink_thread_owned_audiotrack_and_presentation_clock_bounded_pause_resume_closes_reopens_clock_epoch_at_last_published_position_synthetic_armed_dead_object_recovered_once_on_sink_thread_same_parameter_audiotrack_epoch_rebase_real_or_repeated_dead_object_fails_closed_one_forward_mid_stream_seek_while_paused_feed_held_at_window_aligned_anchor_quiescent_audiotrack_flush_once_on_sink_thread_before_transport_seek_seek_clock_epoch_based_at_target_deliberate_discontinuity_stale_generation_rejected_before_jni_two_ordered_forward_seeks_and_third_rejected_without_teardown_production_focus_response_focus_monitor_single_consumer_audiomanager_focus_request_becoming_noisy_receiver_sink_thread_gain_duck_restore_request_ack_transient_pause_auto_resume_user_intent_gated_noisy_terminal_pause_no_auto_resume_permanent_loss_pause_no_auto_resume_stop_dispose_release_once_no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_no_jni';

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
    'syntheticDeadObjectRecoveryOk': true,
    'deadObjectClockEpochRebaseOk': true,
    'deadObjectRemainderAccountingOk': true,
    'seekQuiesceAccountingOk': true,
    'seekCommandOk': true,
    'sinkFlushAtSeekOk': true,
    'decoderSeekReanchorOk': true,
    'staleGenerationRejectedOk': true,
    'seekClockEpochOk': true,
    'postSeekDrainOk': true,
    'repeatedSeekCommandOk': true,
    'repeatedSeekCumulativeAccountingOk': true,
    'repeatedSeekThirdRejectOk': true,
    'focusSetupOk': true,
    'focusDuckRestoreOk': true,
    'focusTransientPauseResumeOk': true,
    'focusNoisyTerminalPauseOk': true,
    'focusPermanentLossPauseOk': true,
    'focusMonitorTeardownOk': true,
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
    'deadObjectInjectAfterFrames': 8192,
    'syntheticDeadObjectInjectAfterFrames': 8192,
    'audioTrackBufferFrames': 3840,
    'deadObjectInjectedCount': 1,
    'deadObjectObservedCount': 1,
    'deadObjectRecoveryCount': 1,
    'deadObjectOldTrackReleaseCount': 1,
    'deadObjectRecoveryExecutedOnSinkThread': true,
    'deadObjectNewTrackInitOk': true,
    'deadObjectNewTrackVolumeOk': true,
    'deadObjectNewTrackPlayOk': true,
    'deadObjectNewTrackPlayState': 3,
    'deadObjectNewTrackSameBuffer': true,
    'deadObjectNewTrackBufferFrames': 3840,
    'deadObjectRecoveryWallMs': 5,
    'deadObjectEpochBeforeRecovery': 0,
    'deadObjectEpochOpenedAfterRecovery': 1,
    'deadObjectEpochCloseAccepted': true,
    'deadObjectEpochOpenAccepted': true,
    'deadObjectPositionBeforeRecovery': 1920,
    'deadObjectBaseFrameAfterRecovery': 8192,
    'deadObjectBaseStepFrames': 6272,
    'deadObjectBaseStepBounded': true,
    'deadObjectContentHeadAtDeadObject': 6400,
    'deadObjectWrittenAheadOfHeadFrames': 1792,
    'deadObjectPublicationLagFrames': 4480,
    'deadObjectBaseStepDecompositionOk': true,
    'deadObjectClockProvenanceAtRecovery': 'ANCHORED',
    'deadObjectClockLastAgeNsAtRecovery': 15000000,
    'deadObjectSliceBytesAtRecovery': 1024,
    'deadObjectUnwrittenBytesAtRecovery': 512,
    'deadObjectBufferPositionAtRecovery': 512,
    'deadObjectFramesReadAtRecovery': 8192,
    'deadObjectFramesWrittenBeforeRecovery': 8192,
    'deadObjectRemainderFramesExpected': 128,
    'deadObjectRemainderFramesWrittenOnNewTrack': 128,
    'deadObjectRemainderAccountingOk': true,
    'deadObjectTimestampPollsDuringRecovery': 0,
    'sinkClockSnapshotsAtDeadObjectRecovery': 1,
    'playbackHeadAtDeadObject': 6400,
    'seekTargetSec': 1.0,
    'secondSeekTargetSec': 2.0,
    'seekTargetSecArmed': 1.0,
    'secondSeekTargetSecArmed': 2.0,
    'preSeekHoldWindows': 64,
    'maxSeekHoldMs': 15000,
    'seekTargetFrame': 48000,
    'preSeekHoldFrame': 20480,
    'target1Frame': 48000,
    'target2Frame': 96000,
    'hold1Frame': 20480,
    'hold2Frame': 64384,
    'sinkHold2Frame': 36864,
    'seekCount': 2,
    'seekAccepted': true,
    'sinkFlushCount': 2,
    'decoderReanchorOk': true,
    'decoderStaleProbeRejected': true,
    'expectedTotalFrames': 84864,
    'postSeekExpectedFrames': 48000,
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
    'focusEnabled': true,
    'focusDuckAppliedCount': 1,
    'focusGainRestoreAppliedCount': 1,
    'focusPauseTransientAppliedCount': 1,
    'focusPauseNoisyAppliedCount': 1,
    'focusPausePermanentAppliedCount': 1,
    'focusAutoResumeAppliedCount': 1,
    'ignoredGainEventsDrained': 6,
    'ignoredGainRestoreAppliedCount': 2,
    'ignoredGainAutoResumeCount': 1,
    'focusState': 'held',
    'sinkEffectiveGain': 0.5,
    'duckGain': 0.1,
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
        'Y8a/Y8b/Y9/Y10b/Y11b realtime audio playback production sink/clock/dead-object/seek/repeated-seek/focus smoke pass=true scenarios=PLAYTHROUGH_BOUNDED_PAUSE_RESUME_TO_EOS,STOP_DISPOSE_MID_PLAYBACK,SYNTHETIC_DEAD_OBJECT_RECOVERY_TO_EOS,SCENARIO_FORWARD_SEEK_TO_EOS,SCENARIO_REPEATED_FORWARD_SEEK_TO_EOS,SCENARIO_FOCUS_DUCK_TRANSIENT_NOISY,SCENARIO_FOCUS_PERMANENT_LOSS',
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
        equals(37),
      );
      expect(
        VGRealtimeAudioPlaybackProductionSmokeReport.requiredLanes.length,
        equals(38),
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
        'syntheticDeadObjectRecoveryOk',
        'deadObjectClockEpochRebaseOk',
        'deadObjectRemainderAccountingOk',
        'seekQuiesceAccountingOk',
        'seekCommandOk',
        'sinkFlushAtSeekOk',
        'decoderSeekReanchorOk',
        'staleGenerationRejectedOk',
        'seekClockEpochOk',
        'postSeekDrainOk',
        'repeatedSeekCommandOk',
        'repeatedSeekCumulativeAccountingOk',
        'repeatedSeekThirdRejectOk',
        'focusSetupOk',
        'focusDuckRestoreOk',
        'focusTransientPauseResumeOk',
        'focusNoisyTerminalPauseOk',
        'focusPermanentLossPauseOk',
        'focusMonitorTeardownOk',
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
      expect(report.syntheticDeadObjectRecoveryOk, isTrue);
      expect(report.deadObjectClockEpochRebaseOk, isTrue);
      expect(report.deadObjectRemainderAccountingOk, isTrue);
      expect(report.seekQuiesceAccountingOk, isTrue);
      expect(report.seekCommandOk, isTrue);
      expect(report.sinkFlushAtSeekOk, isTrue);
      expect(report.decoderSeekReanchorOk, isTrue);
      expect(report.staleGenerationRejectedOk, isTrue);
      expect(report.seekClockEpochOk, isTrue);
      expect(report.postSeekDrainOk, isTrue);
      expect(report.repeatedSeekCommandOk, isTrue);
      expect(report.repeatedSeekCumulativeAccountingOk, isTrue);
      expect(report.repeatedSeekThirdRejectOk, isTrue);
      expect(report.focusSetupOk, isTrue);
      expect(report.focusDuckRestoreOk, isTrue);
      expect(report.focusTransientPauseResumeOk, isTrue);
      expect(report.focusNoisyTerminalPauseOk, isTrue);
      expect(report.focusPermanentLossPauseOk, isTrue);
      expect(report.focusMonitorTeardownOk, isTrue);
      expect(report.focusEnabled, isTrue);
      expect(report.focusDuckAppliedCount, equals(1));
      expect(report.focusGainRestoreAppliedCount, equals(1));
      expect(report.focusPauseTransientAppliedCount, equals(1));
      expect(report.focusPauseNoisyAppliedCount, equals(1));
      expect(report.focusPausePermanentAppliedCount, equals(1));
      expect(report.focusAutoResumeAppliedCount, equals(1));
      expect(report.ignoredGainEventsDrained, equals(6));
      expect(report.ignoredGainRestoreAppliedCount, equals(2));
      expect(report.ignoredGainAutoResumeCount, equals(1));
      expect(report.focusState, equals('held'));
      expect(report.sinkEffectiveGain, equals(0.5));
      expect(report.canonical, isTrue);
      expect(report.allRequiredNonCanonicalLanesPass, isTrue);

      expect(report.metrics['sampleRate'], equals(48000));
      expect(report.metrics['gain'], equals(0.5));
      expect(report.metrics['deadObjectInjectAfterFrames'], equals(8192));
      expect(report.metrics['deadObjectRecoveryCount'], equals(1));
      expect(report.metrics['deadObjectRemainderAccountingOk'], isTrue);
      expect(report.metrics['audioTrackBufferFrames'], equals(3840));
      expect(report.metrics['deadObjectPositionBeforeRecovery'], equals(1920));
      expect(report.metrics['deadObjectBaseStepFrames'], equals(6272));
      expect(report.metrics['deadObjectBaseStepBounded'], isTrue);
      expect(report.metrics['deadObjectContentHeadAtDeadObject'], equals(6400));
      expect(
        report.metrics['deadObjectWrittenAheadOfHeadFrames'],
        equals(1792),
      );
      expect(report.metrics['deadObjectPublicationLagFrames'], equals(4480));
      expect(report.metrics['deadObjectBaseStepDecompositionOk'], isTrue);
      expect(
        report.metrics['deadObjectClockProvenanceAtRecovery'],
        equals('ANCHORED'),
      );
      expect(
        report.metrics['deadObjectClockLastAgeNsAtRecovery'],
        equals(15000000),
      );
      expect(report.metrics['playbackHeadAtDeadObject'], equals(6400));
      expect(report.metrics['seekTargetSec'], equals(1.0));
      expect(report.metrics['secondSeekTargetSec'], equals(2.0));
      expect(report.metrics['preSeekHoldWindows'], equals(64));
      expect(report.metrics['maxSeekHoldMs'], equals(15000));
      expect(report.metrics['seekTargetFrame'], equals(48000));
      expect(report.metrics['preSeekHoldFrame'], equals(20480));
      expect(report.metrics['target1Frame'], equals(48000));
      expect(report.metrics['target2Frame'], equals(96000));
      expect(report.metrics['hold1Frame'], equals(20480));
      expect(report.metrics['hold2Frame'], equals(64384));
      expect(report.metrics['sinkHold2Frame'], equals(36864));
      expect(report.metrics['seekCount'], equals(2));
      expect(report.metrics['seekAccepted'], isTrue);
      expect(report.metrics['sinkFlushCount'], equals(2));
      expect(report.metrics['decoderReanchorOk'], isTrue);
      expect(report.metrics['decoderStaleProbeRejected'], isTrue);
      expect(report.metrics['expectedTotalFrames'], equals(84864));
      expect(report.metrics['postSeekExpectedFrames'], equals(48000));
    });

    test(
      'new Y8b dead-object metric keys parse and are present in metrics map',
      () {
        final report = _createSampleReport();
        expect(
          report.metrics.containsKey('deadObjectContentHeadAtDeadObject'),
          isTrue,
        );
        expect(
          report.metrics['deadObjectContentHeadAtDeadObject'],
          equals(6400),
        );
        expect(
          report.metrics.containsKey('deadObjectWrittenAheadOfHeadFrames'),
          isTrue,
        );
        expect(
          report.metrics['deadObjectWrittenAheadOfHeadFrames'],
          equals(1792),
        );
        expect(
          report.metrics.containsKey('deadObjectPublicationLagFrames'),
          isTrue,
        );
        expect(report.metrics['deadObjectPublicationLagFrames'], equals(4480));
        expect(
          report.metrics.containsKey('deadObjectBaseStepDecompositionOk'),
          isTrue,
        );
        expect(report.metrics['deadObjectBaseStepDecompositionOk'], isTrue);
        expect(
          report.metrics.containsKey('deadObjectClockProvenanceAtRecovery'),
          isTrue,
        );
        expect(
          report.metrics['deadObjectClockProvenanceAtRecovery'],
          equals('ANCHORED'),
        );
        expect(
          report.metrics.containsKey('deadObjectClockLastAgeNsAtRecovery'),
          isTrue,
        );
        expect(
          report.metrics['deadObjectClockLastAgeNsAtRecovery'],
          equals(15000000),
        );
      },
    );

    test('new Y9 seek metric keys parse and are present in metrics map', () {
      final report = _createSampleReport();
      expect(report.metrics.containsKey('seekTargetSec'), isTrue);
      expect(report.metrics['seekTargetSec'], equals(1.0));
      expect(report.metrics.containsKey('preSeekHoldWindows'), isTrue);
      expect(report.metrics['preSeekHoldWindows'], equals(64));
      expect(report.metrics.containsKey('maxSeekHoldMs'), isTrue);
      expect(report.metrics['maxSeekHoldMs'], equals(15000));
      expect(report.metrics.containsKey('seekTargetFrame'), isTrue);
      expect(report.metrics['seekTargetFrame'], equals(48000));
      expect(report.metrics.containsKey('preSeekHoldFrame'), isTrue);
      expect(report.metrics['preSeekHoldFrame'], equals(20480));
      expect(report.metrics.containsKey('seekCount'), isTrue);
      expect(report.metrics['seekCount'], equals(2));
      expect(report.metrics.containsKey('seekAccepted'), isTrue);
      expect(report.metrics['seekAccepted'], isTrue);
      expect(report.metrics.containsKey('sinkFlushCount'), isTrue);
      expect(report.metrics['sinkFlushCount'], equals(2));
      expect(report.metrics.containsKey('decoderReanchorOk'), isTrue);
      expect(report.metrics['decoderReanchorOk'], isTrue);
      expect(report.metrics.containsKey('decoderStaleProbeRejected'), isTrue);
      expect(report.metrics['decoderStaleProbeRejected'], isTrue);
      expect(report.metrics.containsKey('expectedTotalFrames'), isTrue);
      expect(report.metrics['expectedTotalFrames'], equals(84864));
      expect(report.metrics.containsKey('postSeekExpectedFrames'), isTrue);
      expect(report.metrics['postSeekExpectedFrames'], equals(48000));
    });

    test(
      'new Y10b repeated-seek metric keys parse and are present in metrics map',
      () {
        final report = _createSampleReport();
        expect(report.metrics.containsKey('secondSeekTargetSec'), isTrue);
        expect(report.metrics['secondSeekTargetSec'], equals(2.0));
        expect(report.metrics.containsKey('target1Frame'), isTrue);
        expect(report.metrics['target1Frame'], equals(48000));
        expect(report.metrics.containsKey('target2Frame'), isTrue);
        expect(report.metrics['target2Frame'], equals(96000));
        expect(report.metrics.containsKey('hold1Frame'), isTrue);
        expect(report.metrics['hold1Frame'], equals(20480));
        expect(report.metrics.containsKey('hold2Frame'), isTrue);
        expect(report.metrics['hold2Frame'], equals(64384));
        expect(report.metrics.containsKey('sinkHold2Frame'), isTrue);
        expect(report.metrics['sinkHold2Frame'], equals(36864));
        expect(report.metrics.containsKey('expectedTotalFrames'), isTrue);
        expect(report.metrics['expectedTotalFrames'], equals(84864));
      },
    );

    test('new Y11b focus metric keys parse and are present in metrics map', () {
      final report = _createSampleReport();
      expect(report.metrics.containsKey('focusEnabled'), isTrue);
      expect(report.metrics['focusEnabled'], isTrue);
      expect(report.metrics.containsKey('focusDuckAppliedCount'), isTrue);
      expect(report.metrics['focusDuckAppliedCount'], equals(1));
      expect(
        report.metrics.containsKey('focusGainRestoreAppliedCount'),
        isTrue,
      );
      expect(report.metrics['focusGainRestoreAppliedCount'], equals(1));
      expect(
        report.metrics.containsKey('focusPauseTransientAppliedCount'),
        isTrue,
      );
      expect(report.metrics['focusPauseTransientAppliedCount'], equals(1));
      expect(report.metrics.containsKey('focusPauseNoisyAppliedCount'), isTrue);
      expect(report.metrics['focusPauseNoisyAppliedCount'], equals(1));
      expect(
        report.metrics.containsKey('focusPausePermanentAppliedCount'),
        isTrue,
      );
      expect(report.metrics['focusPausePermanentAppliedCount'], equals(1));
      expect(report.metrics.containsKey('focusAutoResumeAppliedCount'), isTrue);
      expect(report.metrics['focusAutoResumeAppliedCount'], equals(1));
      expect(report.metrics.containsKey('ignoredGainEventsDrained'), isTrue);
      expect(report.metrics['ignoredGainEventsDrained'], equals(6));
      expect(
        report.metrics.containsKey('ignoredGainRestoreAppliedCount'),
        isTrue,
      );
      expect(report.metrics['ignoredGainRestoreAppliedCount'], equals(2));
      expect(report.metrics.containsKey('ignoredGainAutoResumeCount'), isTrue);
      expect(report.metrics['ignoredGainAutoResumeCount'], equals(1));
      expect(report.metrics.containsKey('focusState'), isTrue);
      expect(report.metrics['focusState'], equals('held'));
      expect(report.metrics.containsKey('sinkEffectiveGain'), isTrue);
      expect(report.metrics['sinkEffectiveGain'], equals(0.5));
      expect(report.metrics.containsKey('duckGain'), isTrue);
      expect(report.metrics['duckGain'], equals(0.1));
    });

    test('missing one new required Y8b lane fails isVerifiedPass', () {
      for (final lane in <String>[
        'syntheticDeadObjectRecoveryOk',
        'deadObjectClockEpochRebaseOk',
        'deadObjectRemainderAccountingOk',
      ]) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes.remove(lane);
        raw['lanes'] = lanes;
        if (raw['metrics'] is Map) {
          final metrics = Map<String, Object?>.from(raw['metrics'] as Map);
          metrics.remove(lane);
          raw['metrics'] = metrics;
        }
        raw.remove(lane);

        final report = VGRealtimeAudioPlaybackProductionSmokeReport.fromMap(
          raw,
        );
        expect(report.pass, isFalse);
        expect(report.isVerifiedPass, isFalse);
        expect(report.marker, equals(_kFailMarker));
        expect(report.status, equals('missing_lane'));
        expect(report.lastError, equals('missing_lane_$lane'));
      }
    });

    test('missing one new required Y9 lane fails isVerifiedPass', () {
      for (final lane in <String>[
        'seekQuiesceAccountingOk',
        'seekCommandOk',
        'sinkFlushAtSeekOk',
        'decoderSeekReanchorOk',
        'staleGenerationRejectedOk',
        'seekClockEpochOk',
        'postSeekDrainOk',
      ]) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes.remove(lane);
        raw['lanes'] = lanes;
        if (raw['metrics'] is Map) {
          final metrics = Map<String, Object?>.from(raw['metrics'] as Map);
          metrics.remove(lane);
          raw['metrics'] = metrics;
        }
        raw.remove(lane);

        final report = VGRealtimeAudioPlaybackProductionSmokeReport.fromMap(
          raw,
        );
        expect(report.pass, isFalse);
        expect(report.isVerifiedPass, isFalse);
        expect(report.marker, equals(_kFailMarker));
        expect(report.status, equals('missing_lane'));
        expect(report.lastError, equals('missing_lane_$lane'));
      }
    });

    test('missing one new required Y10b lane fails isVerifiedPass', () {
      for (final lane in <String>[
        'repeatedSeekCommandOk',
        'repeatedSeekCumulativeAccountingOk',
        'repeatedSeekThirdRejectOk',
      ]) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes.remove(lane);
        raw['lanes'] = lanes;
        if (raw['metrics'] is Map) {
          final metrics = Map<String, Object?>.from(raw['metrics'] as Map);
          metrics.remove(lane);
          raw['metrics'] = metrics;
        }
        raw.remove(lane);

        final report = VGRealtimeAudioPlaybackProductionSmokeReport.fromMap(
          raw,
        );
        expect(report.pass, isFalse);
        expect(report.isVerifiedPass, isFalse);
        expect(report.marker, equals(_kFailMarker));
        expect(report.status, equals('missing_lane'));
        expect(report.lastError, equals('missing_lane_$lane'));
      }
    });

    test('fail map with deadObjectBaseStepBounded=false fails validation', () {
      final report = _createSampleReport(<String, Object?>{
        'pass': false,
        'status': 'fail',
        'marker': _kFailMarker,
        'failureReason': 'dead_object_base_step_negative',
        'deadObjectClockEpochRebaseOk': false,
        'deadObjectBaseStepBounded': false,
        'canonical': false,
      });

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.status, equals('fail'));
      expect(report.failureReason, equals('dead_object_base_step_negative'));
      expect(report.lastError, equals('dead_object_base_step_negative'));
      expect(report.metrics['deadObjectBaseStepBounded'], isFalse);
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
              deadObjectInjectAfterFrames: 8192,
              seekTargetSec: 1.0,
              secondSeekTargetSec: 2.0,
              preSeekHoldWindows: 64,
              maxSeekHoldMs: 15000,
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
        expect(invokedArguments?['deadObjectInjectAfterFrames'], equals(8192));
        expect(invokedArguments?['seekTargetSec'], equals(1.0));
        expect(invokedArguments?['secondSeekTargetSec'], equals(2.0));
        expect(invokedArguments?['preSeekHoldWindows'], equals(64));
        expect(invokedArguments?['maxSeekHoldMs'], equals(15000));
        expect(report.pass, isTrue);
        expect(report.isVerifiedPass, isTrue);
        expect(report.hasPassMarker, isTrue);
      },
    );

    test('method route passes custom deadObjectInjectAfterFrames', () async {
      Map<Object?, Object?>? invokedArguments;
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        invokedArguments = call.arguments as Map<Object?, Object?>?;
        if (call.method == 'runRealtimeAudioPlaybackProductionSmoke') {
          return _createSampleRawMap();
        }
        return null;
      });

      await VGRealtimeAudioPlaybackProductionSmokeReport.runRealtimeAudioPlaybackProductionSmoke(
        sourcePath: '/tmp/test_clip.mov',
        deadObjectInjectAfterFrames: 16384,
      );

      expect(invokedArguments?['deadObjectInjectAfterFrames'], equals(16384));
      expect(invokedArguments?['seekTargetSec'], equals(1.0));
      expect(invokedArguments?['secondSeekTargetSec'], equals(2.0));
    });

    test(
      'method route passes default seek and focus parameters when omitted',
      () async {
        Map<Object?, Object?>? invokedArguments;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (
          MethodCall call,
        ) async {
          invokedArguments = call.arguments as Map<Object?, Object?>?;
          if (call.method == 'runRealtimeAudioPlaybackProductionSmoke') {
            return _createSampleRawMap();
          }
          return null;
        });

        await VGRealtimeAudioPlaybackProductionSmokeReport.runRealtimeAudioPlaybackProductionSmoke(
          sourcePath: '/tmp/test_clip.mov',
        );

        expect(invokedArguments?['seekTargetSec'], equals(1.0));
        expect(invokedArguments?['secondSeekTargetSec'], equals(2.0));
        expect(invokedArguments?['duckGain'], equals(0.1));
      },
    );

    test('method route passes custom seek and focus parameters', () async {
      Map<Object?, Object?>? invokedArguments;
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        invokedArguments = call.arguments as Map<Object?, Object?>?;
        if (call.method == 'runRealtimeAudioPlaybackProductionSmoke') {
          return _createSampleRawMap();
        }
        return null;
      });

      await VGRealtimeAudioPlaybackProductionSmokeReport.runRealtimeAudioPlaybackProductionSmoke(
        sourcePath: '/tmp/test_clip.mov',
        seekTargetSec: 1.2,
        secondSeekTargetSec: 2.4,
        preSeekHoldWindows: 32,
        maxSeekHoldMs: 10000,
        duckGain: 0.15,
      );

      expect(invokedArguments?['seekTargetSec'], equals(1.2));
      expect(invokedArguments?['secondSeekTargetSec'], equals(2.4));
      expect(invokedArguments?['preSeekHoldWindows'], equals(32));
      expect(invokedArguments?['maxSeekHoldMs'], equals(10000));
      expect(invokedArguments?['duckGain'], equals(0.15));
    });

    test('missing any Y11b focus lane fails isVerifiedPass', () {
      const focusLanes = <String>[
        'focusSetupOk',
        'focusDuckRestoreOk',
        'focusTransientPauseResumeOk',
        'focusNoisyTerminalPauseOk',
        'focusPermanentLossPauseOk',
        'focusMonitorTeardownOk',
      ];
      for (final lane in focusLanes) {
        final report = _createSampleReport(<String, Object?>{lane: false});
        expect(
          report.isVerifiedPass,
          isFalse,
          reason: 'Expected failure when $lane is false',
        );
      }
    });

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
