// vg_realtime_playback_pipeline_integration_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-INTEGRATION-A (Y6a): Android True-DAG Phase 4
// realtime playback pipeline integration diagnostic smoke foundation
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'realtime_playback_pipeline_integration_a_diagnostic_only_real_mediacodec_mediaextractor_streaming_pcm16_to_y5a_external_ingest_seam_native_dag_transport_to_nonzero_gain_audiotrack_sink_base_gain_0_5_single_track_forward_playthrough_no_seek_no_pause_resume_no_interactive_controls_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_latency_drift_loudness_snr_claim_no_resample_no_downmix_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_SMOKE_START';
const _kJsonMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'formatProbeOk': true,
    'preRollOk': true,
    'realDecoderIngestOk': true,
    'nonZeroGainSetOk': true,
    'audioTrackInitOk': true,
    'sinkWriteAccountingOk': true,
    'checksumIdentityOk': true,
    'backpressureObservedOk': true,
    'underrunNonterminalOk': true,
    'eosAccountingOk': true,
    'playbackHeadAdvancedOk': true,
    'transportCompletedOk': true,
    'threadOwnershipOk': true,
    'cancellationOk': true,
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
    'sinkThreadWallMs': 3010,
    'sessionWallMs': 3050,
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
    'listenerCallbacksOnOwner': 4,
    'listenerCallbacksOffOwner': 0,
    'transportCommandsIssued': 3,
    'transportPrepareGeneration': 1,
    'transportStartGeneration': 2,
    'transportGenerationFinal': 2,
    'transportStateBeforeDispose': 'COMPLETED',
    'transportStateFinal': 'DISPOSED',
    'transportStateTransitions': 'IDLE>LOADED>PREPARED>PLAYING>COMPLETED',
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
    'cancelProbeStateAtCancel': 'PLAYING',
    'cancelProbeFramesWrittenAtCancel': 2048,
    'cancelProbeJoinMs': 45,
    'cancelProbeCancellationOk': true,
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'Y6a realtime playback pipeline integration harness pass=true',
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

VGRealtimePlaybackPipelineIntegrationSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(
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

  group('VGRealtimePlaybackPipelineIntegrationSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.methodName,
        equals('runRealtimePlaybackPipelineIntegrationSmoke'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport
            .requiredGateKeys
            .length,
        equals(15),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('formatProbeOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('preRollOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('realDecoderIngestOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('nonZeroGainSetOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('audioTrackInitOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('sinkWriteAccountingOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('checksumIdentityOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('backpressureObservedOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('underrunNonterminalOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('eosAccountingOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('playbackHeadAdvancedOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('transportCompletedOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('threadOwnershipOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('cancellationOk'),
      );
      expect(
        VGRealtimePlaybackPipelineIntegrationSmokeReport.requiredGateKeys,
        contains('lifecycleDisposeOk'),
      );
    });
  });

  group('VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap parsing', () {
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

      // Verify all 15 required gates
      expect(report.formatProbeOk, isTrue);
      expect(report.preRollOk, isTrue);
      expect(report.realDecoderIngestOk, isTrue);
      expect(report.nonZeroGainSetOk, isTrue);
      expect(report.audioTrackInitOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.checksumIdentityOk, isTrue);
      expect(report.backpressureObservedOk, isTrue);
      expect(report.underrunNonterminalOk, isTrue);
      expect(report.eosAccountingOk, isTrue);
      expect(report.playbackHeadAdvancedOk, isTrue);
      expect(report.transportCompletedOk, isTrue);
      expect(report.threadOwnershipOk, isTrue);
      expect(report.cancellationOk, isTrue);
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
      expect(report.metrics['preRollFrames'], equals(4096));
      expect(report.metrics['mediaReleaseClean'], isTrue);
      expect(report.metrics['transportStateFinal'], equals('DISPOSED'));
    });

    test('every required gate false causes isVerifiedPass to fail', () {
      for (final gateKey
          in VGRealtimePlaybackPipelineIntegrationSmokeReport
              .requiredGateKeys) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes[gateKey] = false;
        raw['lanes'] = lanes;

        final report = VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(
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
      lanes.remove('threadOwnershipOk');
      raw['lanes'] = lanes;

      final report = VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(
        raw,
      );
      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_gate'));
      expect(report.lastError, equals('missing_gate_threadOwnershipOk'));
    });

    test('bad proof boundary fails closed', () {
      final raw = _createSampleRawMap({
        'proofBoundary': 'invalid_proof_boundary_string',
      });
      final report = VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(
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
      final report = VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('bad status fails closed', () {
      final raw = _createSampleRawMap({'status': 'fail'});
      final report = VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
    });

    test('non-empty failureReason fails closed', () {
      final raw = _createSampleRawMap({'failureReason': 'preRollOk_failed'});
      final report = VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('preRollOk_failed'));
      expect(report.lastError, equals('preRollOk_failed'));
    });

    test(
      'malformed/non-map MethodChannel payload produces fail-shaped report',
      () {
        final reportNull =
            VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(null);
        expect(reportNull.pass, isFalse);
        expect(reportNull.isVerifiedPass, isFalse);
        expect(reportNull.marker, equals(_kFailMarker));
        expect(reportNull.failureReason, equals('native_result_not_a_map'));
        expect(reportNull.lastError, equals('native_result_not_a_map'));
        expect(reportNull.realDecoderIngestOk, isFalse);

        final reportString =
            VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(
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
          'realDecoderIngestOk': 'true',
          'nonZeroGainSetOk': 'true',
          'audioTrackInitOk': 'true',
          'sinkWriteAccountingOk': 'true',
          'checksumIdentityOk': 'true',
          'backpressureObservedOk': 'true',
          'underrunNonterminalOk': 'true',
          'eosAccountingOk': 'true',
          'playbackHeadAdvancedOk': 'true',
          'transportCompletedOk': 'true',
          'threadOwnershipOk': 'true',
          'cancellationOk': 'true',
          'lifecycleDisposeOk': 'true',
          'proofBoundaryOk': 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{'sampleRate': 48000},
      };

      final report = VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(
        raw,
      );
      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.formatProbeOk, isTrue);
      expect(report.preRollOk, isTrue);
      expect(report.realDecoderIngestOk, isTrue);
      expect(report.metrics['sampleRate'], equals(48000));
    });

    test('nested lane and metric maps are preserved', () {
      final sample = _createSampleRawMap();
      final report = VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(
        sample,
      );

      expect(report.metrics['transportStateFinal'], equals('DISPOSED'));
      expect(report.lanes['realDecoderIngestOk'], isTrue);

      final map = report.toMap();
      expect(map['lanes'], isA<Map>());
      expect(map['metrics'], isA<Map>());
      expect(report.toJson(), equals(map));
    });

    test('toString produces diagnostic representation', () {
      final report = _createSampleReport();
      expect(
        report.toString(),
        contains('VGRealtimePlaybackPipelineIntegrationSmokeReport'),
      );
      expect(report.toString(), contains('realDecoderIngestOk: true'));
      expect(report.toString(), contains('isVerifiedPass: true'));
    });
  });

  group('VGRealtimePlaybackPipelineIntegrationSmokeReport MethodChannel invocation', () {
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
          if (call.method == 'runRealtimePlaybackPipelineIntegrationSmoke') {
            return _createSampleRawMap();
          }
          return null;
        });

        final report =
            await VGRealtimePlaybackPipelineIntegrationSmokeReport.runRealtimePlaybackPipelineIntegrationSmoke(
              sourcePath: '/tmp/test_clip.mov',
              maxDurationSec: 3.0,
              maxFramesPerMix: 512,
              baseVolume: 0.5,
              deadlineMs: 25000,
            );

        expect(
          invokedMethod,
          equals('runRealtimePlaybackPipelineIntegrationSmoke'),
        );
        expect(invokedArguments?['sourcePath'], equals('/tmp/test_clip.mov'));
        expect(invokedArguments?['maxDurationSec'], equals(3.0));
        expect(invokedArguments?['maxFramesPerMix'], equals(512));
        expect(invokedArguments?['baseVolume'], equals(0.5));
        expect(invokedArguments?['deadlineMs'], equals(25000));
        expect(report.pass, isTrue);
        expect(report.isVerifiedPass, isTrue);
        expect(report.hasPassMarker, isTrue);
      },
    );

    test('PlatformException produces harness exception report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runRealtimePlaybackPipelineIntegrationSmoke') {
          throw PlatformException(
            code: 'P4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_SMOKE_BUSY',
            message: 'Diagnostic already running',
          );
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackPipelineIntegrationSmokeReport.runRealtimePlaybackPipelineIntegrationSmoke(
            sourcePath: '/tmp/test_clip.mov',
          );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_SMOKE_BUSY',
        ),
      );
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_SMOKE_BUSY:Diagnostic already running',
        ),
      );
    });

    test('TimeoutException produces fallback error report', () async {
      final customChannel = const MethodChannel(
        'vanguard_media_engine_pipeline_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });

      final report =
          await VGRealtimePlaybackPipelineIntegrationSmokeReport.runRealtimePlaybackPipelineIntegrationSmoke(
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
