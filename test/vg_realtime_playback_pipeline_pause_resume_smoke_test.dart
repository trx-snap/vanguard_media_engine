// vg_realtime_playback_pipeline_pause_resume_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-PAUSE-RESUME (Y6b): Android True-DAG Phase 4
// realtime playback pipeline pause/resume diagnostic smoke foundation
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'realtime_playback_pipeline_pause_resume_diagnostic_only_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_single_track_forward_playthrough_pause_resume_only_sink_park_before_transport_pause_sink_unpark_before_transport_resume_no_seek_no_flush_no_feed_reanchor_no_presentation_clock_no_av_sync_no_interactive_controls_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_product_no_editor_no_app_wiring_no_ios_no_streaming_no_cache_no_cpp_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_SMOKE_START';
const _kJsonMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'formatProbeOk': true,
    'preRollOk': true,
    'initialDrainOk': true,
    'sinkParkAckOk': true,
    'pauseCommandOk': true,
    'sinkPausedOk': true,
    'pauseHoldFrozenOk': true,
    'resumeCommandOk': true,
    'sinkResumedOk': true,
    'postResumeDrainOk': true,
    'sinkWriteAccountingOk': true,
    'checksumIdentityOk': true,
    'playbackHeadAdvancedOk': true,
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
    'pauseHoldMs': 150,
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
    'decoderAcceptedFrames': 144000,
    'decoderDecodedFramesAccepted': 144000,
    'codecChunks': 141,
    'decodedFramesTotal': 144000,
    'framesReadFromTransport': 144000,
    'framesWrittenToSink': 144000,
    'partialWriteCount': 1,
    'zeroWriteCount': 0,
    'drainCalls': 570,
    'emptyDrainCount': 0,
    'playbackHeadFinal': 144000,
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
    'transportCommandsIssued': 5,
    'transportPrepareGeneration': 1,
    'transportStartGeneration': 2,
    'transportPauseGeneration': 2,
    'transportResumeGeneration': 2,
    'transportGenerationFinal': 2,
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
    'pushedFrames': 144000,
    'drainedFrames': 144000,
    'discardedFrames': 0,
    'eosPushed': true,
    'eosDrained': true,
    'lastError': 'none',
    'failureReason': '',
    // Pause / resume specific metrics
    'initialWriteWaitMs': 12,
    'framesWrittenBeforePark': 2048,
    'drainCallsBeforePark': 8,
    'transportStateBeforePark': 'PLAYING',
    'positionFrameBeforePark': 2048,
    'pausePositionLimit': 48000,
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
    'sinkFramesWrittenAtPark': 2048,
    'sinkDrainCallsAtPark': 8,
    'sinkPlaybackHeadAtPark': 1800,
    'sinkPlaybackHeadAtUnpark': 1800,
    'sinkParkedHoldMs': 152,
    'pauseAccepted': true,
    'pauseState': 'PAUSED',
    'pauseReason': '',
    'holdStartNativeState': 'PAUSED',
    'holdEndNativeState': 'PAUSED',
    'holdStartTransportState': 'PAUSED',
    'holdEndTransportState': 'PAUSED',
    'holdStartSinkPlayState': 2,
    'holdEndSinkPlayState': 2,
    'holdStartPositionFrame': 2048,
    'holdEndPositionFrame': 2048,
    'holdStartDispatchCount': 8,
    'holdEndDispatchCount': 8,
    'holdStartPushedFrames': 2048,
    'holdEndPushedFrames': 2048,
    'holdStartDrainCalls': 8,
    'holdEndDrainCalls': 8,
    'holdStartFramesWritten': 2048,
    'holdEndFramesWritten': 2048,
    'holdDispatchDelta': 0,
    'holdPushedDelta': 0,
    'holdDrainCallsDelta': 0,
    'holdWrittenDelta': 0,
    'holdActualMs': 152,
    'resumeAccepted': true,
    'resumeState': 'PLAYING',
    'resumeReason': '',
    'sinkUnparkRequested': true,
    'sinkUnparkAcked': true,
    'sinkUnparkAckWaitMs': 2,
    'framesWrittenAfterUnpark': 2048,
    'drainCallsAfterUnpark': 8,
    'framesWrittenAtResume': 2048,
    'drainCallsAtResume': 8,
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'Y6b realtime playback pipeline pause/resume harness pass=true',
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

VGRealtimePlaybackPipelinePauseResumeSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(
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

  group('VGRealtimePlaybackPipelinePauseResumeSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.methodName,
        equals('runRealtimePlaybackPipelinePauseResumeSmoke'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport
            .requiredGateKeys
            .length,
        equals(16),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('formatProbeOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('preRollOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('initialDrainOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('sinkParkAckOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('pauseCommandOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('sinkPausedOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('pauseHoldFrozenOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('resumeCommandOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('sinkResumedOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('postResumeDrainOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('sinkWriteAccountingOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('checksumIdentityOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('playbackHeadAdvancedOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('transportCompletedOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('threadOwnershipOk'),
      );
      expect(
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.requiredGateKeys,
        contains('lifecycleDisposeOk'),
      );
    });
  });

  group('VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap parsing', () {
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

      // Verify all 16 required gates
      expect(report.formatProbeOk, isTrue);
      expect(report.preRollOk, isTrue);
      expect(report.initialDrainOk, isTrue);
      expect(report.sinkParkAckOk, isTrue);
      expect(report.pauseCommandOk, isTrue);
      expect(report.sinkPausedOk, isTrue);
      expect(report.pauseHoldFrozenOk, isTrue);
      expect(report.resumeCommandOk, isTrue);
      expect(report.sinkResumedOk, isTrue);
      expect(report.postResumeDrainOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.checksumIdentityOk, isTrue);
      expect(report.playbackHeadAdvancedOk, isTrue);
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
      expect(report.metrics['framesWrittenToSink'], equals(144000));
      expect(report.metrics['baseVolume'], equals(0.5));
      expect(report.metrics['pauseHoldMs'], equals(150));
      expect(report.metrics['holdDispatchDelta'], equals(0));
      expect(report.metrics['holdPushedDelta'], equals(0));
      expect(report.metrics['holdDrainCallsDelta'], equals(0));
      expect(report.metrics['holdWrittenDelta'], equals(0));
      expect(report.metrics['sinkPlayStateAtPark'], equals(2));
      expect(report.metrics['sinkPlayStateAfterUnpark'], equals(3));
      expect(report.metrics['mediaReleaseClean'], isTrue);
      expect(report.metrics['transportStateFinal'], equals('DISPOSED'));
    });

    test('every required gate false causes isVerifiedPass to fail', () {
      for (final gateKey
          in VGRealtimePlaybackPipelinePauseResumeSmokeReport
              .requiredGateKeys) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes[gateKey] = false;
        raw['lanes'] = lanes;

        final report = VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(
          raw,
        );
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
      lanes.remove('pauseHoldFrozenOk');
      raw['lanes'] = lanes;

      final report = VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(
        raw,
      );
      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_gate'));
      expect(report.lastError, equals('missing_gate_pauseHoldFrozenOk'));
    });

    test('bad proof boundary fails closed', () {
      final raw = _createSampleRawMap({
        'proofBoundary': 'invalid_proof_boundary_string',
      });
      final report = VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, equals('proof_boundary_mismatch'));
    });

    test('bad marker fails closed', () {
      final raw = _createSampleRawMap({'marker': 'INVALID_MARKER'});
      final report = VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('bad status fails closed', () {
      final raw = _createSampleRawMap({'status': 'fail'});
      final report = VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
    });

    test('non-empty failureReason fails closed', () {
      final raw = _createSampleRawMap({
        'failureReason': 'pauseHoldFrozenOk_failed',
      });
      final report = VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('pauseHoldFrozenOk_failed'));
      expect(report.lastError, equals('pauseHoldFrozenOk_failed'));
    });

    test(
      'malformed/non-map MethodChannel payload produces fail-shaped report',
      () {
        final reportNull =
            VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(null);
        expect(reportNull.pass, isFalse);
        expect(reportNull.isVerifiedPass, isFalse);
        expect(reportNull.marker, equals(_kFailMarker));
        expect(reportNull.failureReason, equals('native_result_not_a_map'));
        expect(reportNull.lastError, equals('native_result_not_a_map'));
        expect(reportNull.pauseCommandOk, isFalse);

        final reportString =
            VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(
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
          'sinkParkAckOk': 'true',
          'pauseCommandOk': 'true',
          'sinkPausedOk': 'true',
          'pauseHoldFrozenOk': 'true',
          'resumeCommandOk': 'true',
          'sinkResumedOk': 'true',
          'postResumeDrainOk': 'true',
          'sinkWriteAccountingOk': 'true',
          'checksumIdentityOk': 'true',
          'playbackHeadAdvancedOk': 'true',
          'transportCompletedOk': 'true',
          'threadOwnershipOk': 'true',
          'lifecycleDisposeOk': 'true',
          'proofBoundaryOk': 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{'sampleRate': 48000},
      };

      final report = VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(
        raw,
      );
      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.formatProbeOk, isTrue);
      expect(report.pauseHoldFrozenOk, isTrue);
      expect(report.resumeCommandOk, isTrue);
      expect(report.metrics['sampleRate'], equals(48000));
    });

    test('nested lane and metric maps are preserved', () {
      final sample = _createSampleRawMap();
      final report = VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(
        sample,
      );

      expect(report.metrics['transportStateFinal'], equals('DISPOSED'));
      expect(report.lanes['pauseHoldFrozenOk'], isTrue);

      final map = report.toMap();
      expect(map['lanes'], isA<Map>());
      expect(map['metrics'], isA<Map>());
      expect(report.toJson(), equals(map));
    });

    test('toString produces diagnostic representation', () {
      final report = _createSampleReport();
      expect(
        report.toString(),
        contains('VGRealtimePlaybackPipelinePauseResumeSmokeReport'),
      );
      expect(report.toString(), contains('pauseHoldFrozenOk: true'));
      expect(report.toString(), contains('isVerifiedPass: true'));
    });
  });

  group('VGRealtimePlaybackPipelinePauseResumeSmokeReport MethodChannel invocation', () {
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
          if (call.method == 'runRealtimePlaybackPipelinePauseResumeSmoke') {
            return _createSampleRawMap();
          }
          return null;
        });

        final report =
            await VGRealtimePlaybackPipelinePauseResumeSmokeReport.runRealtimePlaybackPipelinePauseResumeSmoke(
              sourcePath: '/tmp/test_clip.mov',
              maxDurationSec: 3.0,
              maxFramesPerMix: 512,
              baseVolume: 0.5,
              deadlineMs: 25000,
              pauseHoldMs: 200,
            );

        expect(
          invokedMethod,
          equals('runRealtimePlaybackPipelinePauseResumeSmoke'),
        );
        expect(invokedArguments?['sourcePath'], equals('/tmp/test_clip.mov'));
        expect(invokedArguments?['maxDurationSec'], equals(3.0));
        expect(invokedArguments?['maxFramesPerMix'], equals(512));
        expect(invokedArguments?['baseVolume'], equals(0.5));
        expect(invokedArguments?['deadlineMs'], equals(25000));
        expect(invokedArguments?['pauseHoldMs'], equals(200));
        expect(report.pass, isTrue);
        expect(report.isVerifiedPass, isTrue);
        expect(report.hasPassMarker, isTrue);
      },
    );

    test('PlatformException produces harness exception report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runRealtimePlaybackPipelinePauseResumeSmoke') {
          throw PlatformException(
            code: 'P4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_SMOKE_BUSY',
            message: 'Diagnostic already running',
          );
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackPipelinePauseResumeSmokeReport.runRealtimePlaybackPipelinePauseResumeSmoke(
            sourcePath: '/tmp/test_clip.mov',
          );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_SMOKE_BUSY',
        ),
      );
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_SMOKE_BUSY:Diagnostic already running',
        ),
      );
    });

    test('TimeoutException produces fallback error report', () async {
      final customChannel = const MethodChannel(
        'vanguard_media_engine_pipeline_pause_resume_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });

      final report =
          await VGRealtimePlaybackPipelinePauseResumeSmokeReport.runRealtimePlaybackPipelinePauseResumeSmoke(
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
