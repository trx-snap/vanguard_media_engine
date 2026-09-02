// vg_realtime_playback_real_decoder_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER (Y5b): Android True-DAG Phase 4
// realtime playback real MediaExtractor/MediaCodec PCM16 decode to external ingest seam diagnostic smoke foundation
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'realtime_playback_real_decoder_diagnostic_only_mediacodec_mediaextractor_streaming_pcm16_to_y5a_external_ingest_seam_generation_pinned_owner_thread_handoff_no_presentation_clock_no_av_sync_no_resample_no_downmix_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_REAL_DECODER_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_REAL_DECODER_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_REAL_DECODER_SMOKE_START';
const _kJsonMarker = 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_REAL_DECODER_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'formatProbeOk': true,
    'realDecoderIngestOk': true,
    'seekReanchorOk': true,
    'backpressureRecoveryOk': true,
    'underrunToleranceOk': true,
    'eosAccountingOk': true,
    'staleGenerationRejectedOk': true,
    'lifecycleDisposeOk': true,
    'proofBoundaryOk': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'sourceMime': 'audio/mp4a-latm',
    'sourceDurationUs': 2000000,
    'sourceTrackIndex': 0,
    'sampleRate': 44100,
    'channelCount': 2,
    'pcmEncoding': 2,
    'declaredFrameCount': 44100,
    'maxFramesPerMix': 256,
    'maxDurationSec': 1.0,
    'seekTargetFrame': 15435,
    'preSeekFrames': 1024,
    'playPrerollFrames': 4096,
    'playPrerollPartialWrite': true,
    'playPrerollRingFull': true,
    'playFinalState': 'COMPLETED',
    'playNativeState': 'COMPLETED',
    'playPositionFrame': 44100,
    'playPushedFrames': 44100,
    'playDrainedFrames': 44100,
    'playDiscardedFrames': 0,
    'playEosPushed': true,
    'playEosDrained': true,
    'playAcceptedFrames': 44100,
    'playDecodedFramesAccepted': 44100,
    'playPaddedFrames': 0,
    'playTruncatedFrames': 0,
    'playIngestCalls': 200,
    'playDrainCalls': 400,
    'playTransientRejects': 0,
    'playObservedPartialWrite': true,
    'playObservedRingFull': true,
    'playRemainderRetryAccepted': true,
    'playStarvationObserved': true,
    'playStarvedPositionFrame': 14700,
    'playStarvedUnderrunCount': 1,
    'playFinalUnderrunCount': 1,
    'playBackpressureCount': 2,
    'playKotlinChecksumHex': '00000000abcdef12',
    'playPushedChecksumHex': '00000000abcdef12',
    'playDrainedChecksumHex': '00000000abcdef12',
    'playCodecChunks': 80,
    'playDecodedFramesTotal': 44100,
    'playLastError': 'none',
    'seekFinalState': 'COMPLETED',
    'seekNativeState': 'COMPLETED',
    'seekStaleGeneration': 1,
    'seekNewGeneration': 2,
    'seekParkedUnderrunCount': 1,
    'seekPositionFrame': 44100,
    'seekExpectedPushedFrames': 29689,
    'seekPushedFrames': 29689,
    'seekDrainedFrames': 29689,
    'seekDiscardedFrames': 0,
    'seekPostSeekAcceptedFrames': 28665,
    'seekPaddedFrames': 0,
    'seekTruncatedFrames': 0,
    'seekIngestCalls': 150,
    'seekDrainCalls': 300,
    'seekTransientRejects': 0,
    'seekFinalUnderrunCount': 2,
    'seekKotlinChecksumHex': '00000000abcdef34',
    'seekPushedChecksumHex': '00000000abcdef34',
    'seekDrainedChecksumHex': '00000000abcdef34',
    'seekLastError': 'none',
    'disposeState': 'DISPOSED',
    'disposeIngestReason': 'disposed',
    'disposePostIngestPosted': false,
    'disposeMediaReleaseClean': true,
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'Y5b realtime playback real decoder harness pass=true',
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

VGRealtimePlaybackRealDecoderSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGRealtimePlaybackRealDecoderSmokeReport.fromMap(
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

  group('VGRealtimePlaybackRealDecoderSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.methodName,
        equals('runRealtimePlaybackRealDecoderSmoke'),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.requiredGateKeys.length,
        equals(8),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.requiredGateKeys,
        contains('formatProbeOk'),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.requiredGateKeys,
        contains('realDecoderIngestOk'),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.requiredGateKeys,
        contains('seekReanchorOk'),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.requiredGateKeys,
        contains('backpressureRecoveryOk'),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.requiredGateKeys,
        contains('underrunToleranceOk'),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.requiredGateKeys,
        contains('eosAccountingOk'),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.requiredGateKeys,
        contains('staleGenerationRejectedOk'),
      );
      expect(
        VGRealtimePlaybackRealDecoderSmokeReport.requiredGateKeys,
        contains('lifecycleDisposeOk'),
      );
    });
  });

  group('VGRealtimePlaybackRealDecoderSmokeReport.fromMap parsing', () {
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

      // Verify gates
      expect(report.formatProbeOk, isTrue);
      expect(report.realDecoderIngestOk, isTrue);
      expect(report.seekReanchorOk, isTrue);
      expect(report.backpressureRecoveryOk, isTrue);
      expect(report.underrunToleranceOk, isTrue);
      expect(report.eosAccountingOk, isTrue);
      expect(report.staleGenerationRejectedOk, isTrue);
      expect(report.lifecycleDisposeOk, isTrue);
      expect(report.proofBoundaryOk, isTrue);
      expect(report.canonical, isTrue);

      // Verify metrics in metrics map
      expect(report.metrics['sourceMime'], equals('audio/mp4a-latm'));
      expect(report.metrics['sampleRate'], equals(44100));
      expect(report.metrics['channelCount'], equals(2));
      expect(report.metrics['declaredFrameCount'], equals(44100));
      expect(report.metrics['playPushedFrames'], equals(44100));
      expect(report.metrics['playStarvationObserved'], isTrue);
      expect(report.metrics['seekStaleGeneration'], equals(1));
      expect(report.metrics['seekNewGeneration'], equals(2));
      expect(report.metrics['disposeMediaReleaseClean'], isTrue);
      expect(report.metrics['disposeState'], equals('DISPOSED'));
    });

    test('every required gate false causes isVerifiedPass to fail', () {
      for (final gateKey
          in VGRealtimePlaybackRealDecoderSmokeReport.requiredGateKeys) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes[gateKey] = false;
        raw['lanes'] = lanes;

        final report = VGRealtimePlaybackRealDecoderSmokeReport.fromMap(raw);
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
      lanes.remove('seekReanchorOk');
      raw['lanes'] = lanes;

      final report = VGRealtimePlaybackRealDecoderSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_gate'));
      expect(report.lastError, equals('missing_gate_seekReanchorOk'));
    });

    test('bad proof boundary fails closed', () {
      final raw = _createSampleRawMap({
        'proofBoundary': 'invalid_proof_boundary_string',
      });
      final report = VGRealtimePlaybackRealDecoderSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, equals('proof_boundary_mismatch'));
    });

    test('bad marker fails closed', () {
      final raw = _createSampleRawMap({'marker': 'INVALID_MARKER'});
      final report = VGRealtimePlaybackRealDecoderSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('bad status fails closed', () {
      final raw = _createSampleRawMap({'status': 'fail'});
      final report = VGRealtimePlaybackRealDecoderSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
    });

    test('non-empty failureReason fails closed', () {
      final raw = _createSampleRawMap({
        'failureReason': 'seek_preroll_short:128',
      });
      final report = VGRealtimePlaybackRealDecoderSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('seek_preroll_short:128'));
      expect(report.lastError, equals('seek_preroll_short:128'));
    });

    test(
      'malformed/non-map MethodChannel payload produces fail-shaped report',
      () {
        final reportNull = VGRealtimePlaybackRealDecoderSmokeReport.fromMap(
          null,
        );
        expect(reportNull.pass, isFalse);
        expect(reportNull.isVerifiedPass, isFalse);
        expect(reportNull.marker, equals(_kFailMarker));
        expect(reportNull.failureReason, equals('native_result_not_a_map'));
        expect(reportNull.lastError, equals('native_result_not_a_map'));
        expect(reportNull.realDecoderIngestOk, isFalse);

        final reportString = VGRealtimePlaybackRealDecoderSmokeReport.fromMap(
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
          'realDecoderIngestOk': 'true',
          'seekReanchorOk': 'ok',
          'backpressureRecoveryOk': 'true',
          'underrunToleranceOk': 'true',
          'eosAccountingOk': 'true',
          'staleGenerationRejectedOk': 'true',
          'lifecycleDisposeOk': 'true',
          'proofBoundaryOk': 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{'sampleRate': 44100},
      };

      final report = VGRealtimePlaybackRealDecoderSmokeReport.fromMap(raw);
      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.formatProbeOk, isTrue);
      expect(report.realDecoderIngestOk, isTrue);
      expect(report.seekReanchorOk, isTrue);
      expect(report.metrics['sampleRate'], equals(44100));
    });

    test('nested lane and metric maps are preserved', () {
      final sample = _createSampleRawMap();
      final report = VGRealtimePlaybackRealDecoderSmokeReport.fromMap(sample);

      expect(report.metrics['playFinalState'], equals('COMPLETED'));
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
        contains('VGRealtimePlaybackRealDecoderSmokeReport'),
      );
      expect(report.toString(), contains('realDecoderIngestOk: true'));
      expect(report.toString(), contains('isVerifiedPass: true'));
    });
  });

  group('VGRealtimePlaybackRealDecoderSmokeReport MethodChannel invocation', () {
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
          if (call.method == 'runRealtimePlaybackRealDecoderSmoke') {
            return _createSampleRawMap();
          }
          return null;
        });

        final report =
            await VGRealtimePlaybackRealDecoderSmokeReport.runRealtimePlaybackRealDecoderSmoke(
              sourcePath: '/tmp/test_clip.mov',
              maxDurationSec: 1.5,
              seekTargetSec: 0.5,
              maxFramesPerMix: 512,
              deadlineMs: 25000,
            );

        expect(invokedMethod, equals('runRealtimePlaybackRealDecoderSmoke'));
        expect(invokedArguments?['sourcePath'], equals('/tmp/test_clip.mov'));
        expect(invokedArguments?['maxDurationSec'], equals(1.5));
        expect(invokedArguments?['seekTargetSec'], equals(0.5));
        expect(invokedArguments?['maxFramesPerMix'], equals(512));
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
        if (call.method == 'runRealtimePlaybackRealDecoderSmoke') {
          throw PlatformException(
            code: 'P4_REALTIME_PLAYBACK_REAL_DECODER_SMOKE_BUSY',
            message: 'Diagnostic already running',
          );
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackRealDecoderSmokeReport.runRealtimePlaybackRealDecoderSmoke(
            sourcePath: '/tmp/test_clip.mov',
          );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_REAL_DECODER_SMOKE_BUSY',
        ),
      );
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_REALTIME_PLAYBACK_REAL_DECODER_SMOKE_BUSY:Diagnostic already running',
        ),
      );
    });

    test('TimeoutException produces fallback error report', () async {
      final customChannel = const MethodChannel(
        'vanguard_media_engine_real_decoder_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });

      final report =
          await VGRealtimePlaybackRealDecoderSmokeReport.runRealtimePlaybackRealDecoderSmoke(
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
