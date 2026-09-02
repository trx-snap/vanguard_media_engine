// vg_realtime_playback_pipeline_seek_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SEEK (Y6c): Android True-DAG Phase 4
// realtime playback pipeline seek diagnostic smoke foundation
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'realtime_playback_pipeline_seek_diagnostic_only_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_single_track_one_forward_mid_stream_seek_while_paused_feed_held_at_window_aligned_anchor_quiescent_pushed_eq_drained_eq_anchor_discarded_0_sink_park_before_transport_pause_audiotrack_flush_once_on_sink_thread_before_transport_seek_feed_reanchor_generation_pinned_stale_pre_seek_ingest_rejected_before_jni_two_epoch_sink_accounting_epoch_relative_playback_head_no_presentation_clock_no_av_sync_no_latency_no_glitch_no_loudness_no_snr_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_interactive_ui_no_product_no_editor_no_app_wiring_no_ios_no_streaming_no_cache_no_cpp_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_SMOKE_START';
const _kJsonMarker = 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'formatProbeOk': true,
    'preRollOk': true,
    'initialDrainOk': true,
    'seekQuiesceAccountingOk': true,
    'pauseCommandOk': true,
    'sinkPausedOk': true,
    'seekCommandOk': true,
    'sinkFlushAtSeekOk': true,
    'realDecoderSeekReanchorOk': true,
    'staleGenerationRejectedOk': true,
    'sinkResumedOk': true,
    'postSeekDrainOk': true,
    'sinkWriteAccountingOk': true,
    'checksumIdentityOk': true,
    'postSeekPlaybackHeadAdvancedOk': true,
    'transportCompletedOk': true,
    'threadOwnershipOk': true,
    'lifecycleDisposeOk': true,
    'proofBoundaryOk': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'sourceMime': 'audio/mp4a-latm',
    'sourceDurationUs': 3000000,
    'sourceTrackIndex': 0,
    'sampleRate': 48000,
    'channelCount': 2,
    'pcmEncoding': 2,
    'declaredFrameCount': 144000,
    'maxFramesPerMix': 256,
    'maxDurationSec': 3.0,
    'baseVolume': 0.5,
    'deadlineMs': 30000,
    'seekTargetSec': 1.5,
    'preSeekHoldWindows': 64,
    'preRollFrames': 4096,
    'preRollRingFullObserved': true,
    'preRollPartialWriteObserved': false,
    'preRollStatePrepared': true,
    'ingestRingFullCount': 5,
    'ingestPartialWriteCount': 2,
    'ingestCalls': 600,
    'staleGenerationRetries': 0,
    'transientRejects': 0,
    'nativeBackpressureCount': 7,
    'nativeUnderrunCount': 0,
    'nativeDispatchCount': 563,
    'eosPaddedFrames': 0,
    'eosTruncatedFrames': 0,
    'decoderDiscardedFrames': 0,
    'decoderAcceptedFrames': 92432,
    'decoderAnchorFrame': 144000,
    'codecChunks': 141,
    'decodedFramesTotal': 144000,
    'framesReadFromTransport': 92432,
    'framesWrittenToSink': 92432,
    'partialWriteCount': 1,
    'zeroWriteCount': 0,
    'drainCalls': 570,
    'emptyDrainCount': 0,
    'playbackHeadFinal': 72000,
    'playbackHeadCaughtUp': true,
    'audioTrackInitOk': true,
    'gainSetOk': true,
    'gainValue': 0.5,
    'audioTrackBufferBytes': 16384,
    'decodeThreadWallMs': 2950,
    'sinkThreadWallMs': 3160,
    'sessionWallMs': 3200,
    'kotlinDecoderChecksumHex': '0000000012345678',
    'kotlinSinkChecksumHex': '0000000012345678',
    'nativePushedChecksumHex': '0000000012345678',
    'nativeDrainedChecksumHex': '0000000012345678',
    'mediaReleaseCount': 1,
    'mediaReleaseClean': true,
    'mediaReopens': 0,
    'audioTrackReleaseCount': 1,
    'transportDisposeCalls': 1,
    'decoderThreadJoined': true,
    'sinkThreadJoined': true,
    'decoderExitReason': 'eos',
    'sinkExitReason': 'eos',
    'decoderThreadId': 101,
    'sinkThreadId': 102,
    'ingestCallbacksOnOwner': 600,
    'ingestCallbacksOffOwner': 0,
    'listenerCallbacksOnOwner': 6,
    'listenerCallbacksOffOwner': 0,
    'transportCommandsIssued': 6,
    'transportPrepareGeneration': 1,
    'transportStartGeneration': 2,
    'transportPauseGeneration': 2,
    'transportSeekStaleGeneration': 2,
    'transportSeekGeneration': 3,
    'transportResumeGeneration': 3,
    'transportGenerationFinal': 3,
    'transportStateBeforeDispose': 'COMPLETED',
    'transportStateFinal': 'DISPOSED',
    'transportStateTransitions':
        'IDLE>LOADED>PREPARED>PLAYING>PAUSED>PLAYING>COMPLETED',
    'transportCompletedCallbacks': 1,
    'transportFailedCallbacks': 0,
    'postIngestAfterDisposePosted': false,
    'nativeStateFinal': 'COMPLETED',
    'nativeWorkerExited': true,
    'nativeWorkerJoined': true,
    'positionFrame': 144000,
    'pushedFrames': 92432,
    'drainedFrames': 92432,
    'discardedFrames': 0,
    'eosPushed': true,
    'eosDrained': true,
    'lastError': 'none',
    'failureReason': '',
    // Seek-specific metrics
    'seekTargetFrame': 72000,
    'preSeekHoldFrame': 20432,
    'seekAdmissionOk': true,
    'holdPinned': true,
    'expectedTotalSinkFrames': 92432,
    'initialWriteWaitMs': 12,
    'framesWrittenBeforeHold': 2048,
    'drainCallsBeforeHold': 8,
    'transportStateBeforeHold': 'PLAYING',
    'quiesceWaitMs': 45,
    'quiesceFeedHeld': true,
    'quiesceSinkReadFrames': 20432,
    'quiesceSinkWrittenFrames': 20432,
    'quiesceAccountingOk': true,
    'preSeekSnapshotSettleMs': 2,
    'preSeekNativeState': 'PLAYING',
    'preSeekTransportState': 'PLAYING',
    'preSeekPositionFrame': 20432,
    'preSeekPushedFrames': 20432,
    'preSeekDrainedFrames': 20432,
    'preSeekDiscardedFrames': 0,
    'preSeekUnderrunCount': 0,
    'preSeekOutputAvailableReadFrames': 0,
    'decoderPreSeekAcceptedFrames': 20432,
    'decoderStagedFramesClearedAtSeek': 0,
    'sinkParkRequested': true,
    'sinkParkAcked': true,
    'sinkParkAckWaitMs': 3,
    'sinkParkAckLatencyMs': 3,
    'sinkParkCount': 1,
    'sinkUnparkCount': 1,
    'sinkParkRequestCount': 1,
    'sinkPhaseFinal': 'RUNNING',
    'sinkPlayStateAtPark': 2,
    'sinkPlayStateAfterUnpark': 3,
    'sinkParkedPlayStateObservations': 30,
    'sinkParkedPlayStateViolations': 0,
    'sinkParkExecutedOnSinkThread': true,
    'sinkUnparkExecutedOnSinkThread': true,
    'sinkFramesWrittenAtPark': 20432,
    'sinkDrainCallsAtPark': 80,
    'sinkPlaybackHeadAtPark': 18000,
    'sinkPlaybackHeadAtUnpark': 18000,
    'sinkParkedHoldMs': 152,
    'pauseAccepted': true,
    'pauseState': 'PAUSED',
    'pauseReason': '',
    'postPauseNativeState': 'PAUSED',
    'postPausePushedFrames': 20432,
    'postPauseDrainedFrames': 20432,
    'sinkFlushRequested': true,
    'sinkFlushAcked': true,
    'sinkFlushAckWaitMs': 2,
    'sinkFlushAckLatencyMs': 2,
    'sinkFlushRequestCount': 1,
    'sinkFlushCount': 1,
    'sinkFlushExecutedOnSinkThread': true,
    'sinkPlayStateBeforeFlush': 2,
    'sinkPlayStateAfterFlush': 2,
    'sinkPlaybackHeadBeforeFlush': 18000,
    'sinkPlaybackHeadAfterFlush': 0,
    'sinkFramesWrittenAtFlush': 20432,
    'sinkFramesReadAtFlush': 20432,
    'sinkDrainCallsAtFlush': 80,
    'sinkPostSeekExpectedFrames': 72000,
    'sinkReadBudgetFrames': 92432,
    'seekAccepted': true,
    'seekState': 'PAUSED',
    'seekReason': '',
    'sinkPlayStateAtSeek': 2,
    'sinkPhaseAtSeek': 'PARKED',
    'postSeekNativeState': 'PAUSED',
    'postSeekTransportState': 'PAUSED',
    'postSeekPositionFrame': 72000,
    'postSeekPushedFrames': 20432,
    'postSeekDrainedFrames': 20432,
    'postSeekDiscardedFrames': 0,
    'feedReanchorRequested': true,
    'feedReanchorAcked': true,
    'feedReanchorWaitMs': 5,
    'feedReanchorWallMs': 5,
    'feedReanchorCount': 1,
    'feedReanchorExecutedOnDecodeThread': true,
    'feedReanchorTransportStatePaused': true,
    'seekTargetUs': 1500000,
    'seekLandedUs': 1480000,
    'seekStaleProbeCalls': 1,
    'seekStaleReason': 'stale_generation',
    'seekStaleReplyNull': true,
    'seekStaleRejected': true,
    'seekStaleAnchorUntouched': true,
    'seekDiscardedPreTargetFrames': 960,
    'seekGapObservedFrames': 0,
    'seekGapPaddedFrames': 0,
    'seekMaxGapFrames': 12000,
    'seekFirstDecodedPtsUs': 1500000,
    'seekFirstDecodedFrame': 72000,
    'postSeekAcceptedFrames': 72000,
    'postSeekDecodedAcceptedFrames': 72000,
    'postSeekPaddedFrames': 0,
    'postSeekPreRollAcked': true,
    'postSeekPreRollWaitMs': 8,
    'postSeekPreRollFrames': 1024,
    'postSeekPreRollStatePaused': true,
    'postSeekPreRollTransportState': 'PAUSED',
    'postSeekPreRollNativeState': 'PAUSED',
    'postSeekPreRollPushedFrames': 20432,
    'sinkUnparkRequested': true,
    'sinkUnparkAcked': true,
    'sinkUnparkAckWaitMs': 2,
    'framesWrittenAfterUnpark': 20432,
    'drainCallsAfterUnpark': 80,
    'resumeAccepted': true,
    'resumeState': 'PLAYING',
    'resumeReason': '',
    'framesWrittenAtResume': 20432,
    'drainCallsAtResume': 80,
    'sinkPlaybackHeadEpochBase': 0,
    'sinkEpochBaseCaptured': true,
    'postSeekPlaybackHeadFrames': 72000,
    'postSeekFramesWritten': 72000,
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'Y6c realtime playback pipeline seek harness pass=true',
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

VGRealtimePlaybackPipelineSeekSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(
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

  group('VGRealtimePlaybackPipelineSeekSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.methodName,
        equals('runRealtimePlaybackPipelineSeekSmoke'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys.length,
        equals(18),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('formatProbeOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('preRollOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('initialDrainOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('seekQuiesceAccountingOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('pauseCommandOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('sinkPausedOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('seekCommandOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('sinkFlushAtSeekOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('realDecoderSeekReanchorOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('staleGenerationRejectedOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('sinkResumedOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('postSeekDrainOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('sinkWriteAccountingOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('checksumIdentityOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('postSeekPlaybackHeadAdvancedOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('transportCompletedOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('threadOwnershipOk'),
      );
      expect(
        VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys,
        contains('lifecycleDisposeOk'),
      );
    });
  });

  group('VGRealtimePlaybackPipelineSeekSmokeReport.fromMap parsing', () {
    test('pass payload parses true with all gates and metrics', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.marker, equals(_kPassMarker));
      expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.nativeProofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.isVerifiedPass, isTrue);
      expect(report.lastError, isEmpty);
      expect(report.failureReason, isEmpty);

      // Verify all 18 required gates
      expect(report.formatProbeOk, isTrue);
      expect(report.preRollOk, isTrue);
      expect(report.initialDrainOk, isTrue);
      expect(report.seekQuiesceAccountingOk, isTrue);
      expect(report.pauseCommandOk, isTrue);
      expect(report.sinkPausedOk, isTrue);
      expect(report.seekCommandOk, isTrue);
      expect(report.sinkFlushAtSeekOk, isTrue);
      expect(report.realDecoderSeekReanchorOk, isTrue);
      expect(report.staleGenerationRejectedOk, isTrue);
      expect(report.sinkResumedOk, isTrue);
      expect(report.postSeekDrainOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.checksumIdentityOk, isTrue);
      expect(report.postSeekPlaybackHeadAdvancedOk, isTrue);
      expect(report.transportCompletedOk, isTrue);
      expect(report.threadOwnershipOk, isTrue);
      expect(report.lifecycleDisposeOk, isTrue);
      expect(report.proofBoundaryOk, isTrue);
      expect(report.canonical, isTrue);

      // Verify metrics in metrics map
      expect(report.metrics['sourceMime'], equals('audio/mp4a-latm'));
      expect(report.metrics['sampleRate'], equals(48000));
      expect(report.metrics['channelCount'], equals(2));
      expect(report.metrics['declaredFrameCount'], equals(144000));
      expect(report.metrics['framesWrittenToSink'], equals(92432));
      expect(report.metrics['baseVolume'], equals(0.5));
      expect(report.metrics['seekTargetSec'], equals(1.5));
      expect(report.metrics['seekTargetFrame'], equals(72000));
      expect(report.metrics['preSeekHoldFrame'], equals(20432));
      expect(report.metrics['quiesceFeedHeld'], isTrue);
      expect(report.metrics['sinkPlayStateAtPark'], equals(2));
      expect(report.metrics['sinkPlayStateAfterFlush'], equals(2));
      expect(report.metrics['sinkPlayStateAfterUnpark'], equals(3));
      expect(report.metrics['mediaReleaseClean'], isTrue);
      expect(report.metrics['transportStateFinal'], equals('DISPOSED'));
    });

    test('every required gate false causes isVerifiedPass to fail', () {
      for (final gateKey
          in VGRealtimePlaybackPipelineSeekSmokeReport.requiredGateKeys) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes[gateKey] = false;
        raw['lanes'] = lanes;

        final report = VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(raw);
        expect(
          report.isVerifiedPass,
          isFalse,
          reason: 'Gate $gateKey set to false should fail isVerifiedPass',
        );
        expect(
          report.pass,
          isFalse,
          reason: 'Gate $gateKey set to false should fail pass',
        );
        expect(report.marker, equals(_kFailMarker));
      }
    });

    test('missing required gate fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes.remove('seekQuiesceAccountingOk');
      raw['lanes'] = lanes;

      final report = VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_gate'));
      expect(report.lastError, equals('missing_gate_seekQuiesceAccountingOk'));
    });

    test('bad proof boundary fails closed', () {
      final raw = _createSampleRawMap({
        'proofBoundary': 'invalid_proof_boundary_string',
      });
      final report = VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, equals('proof_boundary_mismatch'));
    });

    test('bad marker fails closed', () {
      final raw = _createSampleRawMap({'marker': 'INVALID_MARKER'});
      final report = VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('bad status fails closed', () {
      final raw = _createSampleRawMap({'status': 'fail'});
      final report = VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
    });

    test('non-empty failureReason fails closed', () {
      final raw = _createSampleRawMap({
        'failureReason': 'seekQuiesceAccountingOk_failed',
      });
      final report = VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('seekQuiesceAccountingOk_failed'));
      expect(report.lastError, equals('seekQuiesceAccountingOk_failed'));
    });

    test(
      'malformed/non-map MethodChannel payload produces fail-shaped report',
      () {
        final reportNull = VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(
          null,
        );
        expect(reportNull.pass, isFalse);
        expect(reportNull.isVerifiedPass, isFalse);
        expect(reportNull.marker, equals(_kFailMarker));
        expect(reportNull.failureReason, equals('native_result_not_a_map'));
        expect(reportNull.lastError, equals('native_result_not_a_map'));
        expect(reportNull.pauseCommandOk, isFalse);
        expect(reportNull.seekCommandOk, isFalse);

        final reportString = VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(
          'string_error',
        );
        expect(reportString.pass, isFalse);
        expect(reportString.isVerifiedPass, isFalse);
        expect(reportString.marker, equals(_kFailMarker));
        expect(reportString.failureReason, equals('native_result_not_a_map'));
      },
    );

    test('defensive parsing handles string-encoded booleans', () {
      final raw = <String, Object?>{
        'pass': 'true',
        'status': 'PASS',
        'marker': _kPassMarker,
        'proofBoundary': _kCanonicalProofBoundary,
        'failureReason': '',
        'lanes': <String, Object?>{
          'formatProbeOk': 'true',
          'preRollOk': 'true',
          'initialDrainOk': 'true',
          'seekQuiesceAccountingOk': 'true',
          'pauseCommandOk': 'true',
          'sinkPausedOk': 'true',
          'seekCommandOk': 'true',
          'sinkFlushAtSeekOk': 'true',
          'realDecoderSeekReanchorOk': 'true',
          'staleGenerationRejectedOk': 'true',
          'sinkResumedOk': 'true',
          'postSeekDrainOk': 'true',
          'sinkWriteAccountingOk': 'true',
          'checksumIdentityOk': 'true',
          'postSeekPlaybackHeadAdvancedOk': 'true',
          'transportCompletedOk': 'true',
          'threadOwnershipOk': 'true',
          'lifecycleDisposeOk': 'true',
          'proofBoundaryOk': 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{'sampleRate': 48000},
      };

      final report = VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(raw);
      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.formatProbeOk, isTrue);
      expect(report.seekQuiesceAccountingOk, isTrue);
      expect(report.seekCommandOk, isTrue);
      expect(report.metrics['sampleRate'], equals(48000));
    });

    test('nested lane and metric maps are preserved', () {
      final sample = _createSampleRawMap();
      final report = VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(sample);

      expect(report.metrics['transportStateFinal'], equals('DISPOSED'));
      expect(report.lanes['seekQuiesceAccountingOk'], isTrue);

      final map = report.toMap();
      expect(map['lanes'], isA<Map>());
      expect(map['metrics'], isA<Map>());
      expect(report.toJson(), equals(map));
    });

    test('toString produces diagnostic representation', () {
      final report = _createSampleReport();
      expect(
        report.toString(),
        contains('VGRealtimePlaybackPipelineSeekSmokeReport'),
      );
      expect(report.toString(), contains('seekQuiesceAccountingOk: true'));
      expect(report.toString(), contains('isVerifiedPass: true'));
    });
  });

  group('VGRealtimePlaybackPipelineSeekSmokeReport MethodChannel invocation', () {
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
          if (call.method == 'runRealtimePlaybackPipelineSeekSmoke') {
            return _createSampleRawMap();
          }
          return null;
        });

        final report =
            await VGRealtimePlaybackPipelineSeekSmokeReport.runRealtimePlaybackPipelineSeekSmoke(
              sourcePath: '/tmp/test_clip.mov',
              maxDurationSec: 3.0,
              maxFramesPerMix: 512,
              baseVolume: 0.5,
              deadlineMs: 25000,
              seekTargetSec: 1.5,
              preSeekHoldWindows: 64,
            );

        expect(invokedMethod, equals('runRealtimePlaybackPipelineSeekSmoke'));
        expect(invokedArguments?['sourcePath'], equals('/tmp/test_clip.mov'));
        expect(invokedArguments?['maxDurationSec'], equals(3.0));
        expect(invokedArguments?['maxFramesPerMix'], equals(512));
        expect(invokedArguments?['baseVolume'], equals(0.5));
        expect(invokedArguments?['deadlineMs'], equals(25000));
        expect(invokedArguments?['seekTargetSec'], equals(1.5));
        expect(invokedArguments?['preSeekHoldWindows'], equals(64));
        expect(report.pass, isTrue);
        expect(report.isVerifiedPass, isTrue);
        expect(report.hasPassMarker, isTrue);
      },
    );

    test('PlatformException produces harness exception report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runRealtimePlaybackPipelineSeekSmoke') {
          throw PlatformException(
            code: 'P4_REALTIME_PLAYBACK_PIPELINE_SEEK_SMOKE_BUSY',
            message: 'Diagnostic already running',
          );
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackPipelineSeekSmokeReport.runRealtimePlaybackPipelineSeekSmoke(
            sourcePath: '/tmp/test_clip.mov',
          );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_PIPELINE_SEEK_SMOKE_BUSY',
        ),
      );
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_REALTIME_PLAYBACK_PIPELINE_SEEK_SMOKE_BUSY:Diagnostic already running',
        ),
      );
    });

    test('TimeoutException produces fallback error report', () async {
      final customChannel = const MethodChannel(
        'vanguard_media_engine_pipeline_seek_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });

      final report =
          await VGRealtimePlaybackPipelineSeekSmokeReport.runRealtimePlaybackPipelineSeekSmoke(
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
