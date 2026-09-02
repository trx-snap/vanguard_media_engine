// vg_realtime_playback_ingest_seam_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-EXTERNAL-INGEST-SEAM (Y5a): Android True-DAG Phase 4
// realtime playback external PCM16 ingest seam diagnostic smoke foundation
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'realtime_playback_external_ingest_seam_diagnostic_only_kotlin_synthetic_pcm_to_y_series_native_source_ring_owner_thread_ingest_generation_pinned_no_mediacodec_no_mediaextractor_no_decoder_lifecycle_no_presentation_clock_no_av_sync_no_audio_quality_claim_no_latency_claim_no_fleet_claim_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_src_audio_primitive_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INGEST_SEAM_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INGEST_SEAM_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INGEST_SEAM_SMOKE_START';
const _kJsonMarker = 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INGEST_SEAM_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'ingestIdentityOk': true,
    'seekReanchorOk': true,
    'backpressureOk': true,
    'directNativeGuardsOk': true,
    'underrunNonterminalOk': true,
    'staleGenerationOk': true,
    'lifecycleDisposeOk': true,
    'proofBoundaryOk': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'identityPrerollFrames': 1024,
    'identityIngestCalls': 12,
    'identityAcceptedFrames': 12000,
    'identityDrainCalls': 48,
    'identitySampleMismatches': 0,
    'identityUnderrunCount': 0,
    'identityPushedChecksumHex': '00000000abcdef12',
    'identityDrainedChecksumHex': '00000000abcdef12',
    'identityReferenceChecksumHex': '00000000abcdef12',
    'identityFinalState': 'COMPLETED',
    'seekFirstIngestOk': true,
    'seekAccepted': true,
    'seekStaleAnchorRejected': true,
    'seekStaleStatus': 'expected_start_mismatch',
    'seekStaleNextWriteFrame': 6000,
    'seekReanchorNext': 12000,
    'seekDrainedFrames': 6000,
    'seekReferenceChecksumHex': '00000000abcdef34',
    'seekDrainedChecksumHex': '00000000abcdef34',
    'seekSampleMismatches': 0,
    'backpressurePartialStatus': 'partial_write',
    'backpressurePartialAccepted': 4096,
    'backpressurePartialFreeFrames': 0,
    'backpressureFullStatus': 'ring_full',
    'backpressureFullAccepted': 0,
    'backpressureRecoveryAccepted': 256,
    'backpressureRecoveryStatus': 'ok',
    'guardWrongOwnerStatus': 'wrong_owner_thread',
    'guardFormatMismatchStatus': 'format_mismatch',
    'guardSyntheticTrackStatus': 'track_not_external',
    'guardHeapBufferStatus': 'non_direct_buffer',
    'guardOwnerIngestStatus': 'ok',
    'guardOwnerNextWriteFrame': 256,
    'nativeFirstDestroyStatus': 'ok',
    'nativeFirstDestroyWorkerJoined': true,
    'nativeSecondDestroyStatus': 'session_closed',
    'underrunPrerollOk': true,
    'underrunStarvedState': 'playing',
    'underrunStarvedUnderrunCount': 1,
    'underrunStarvedPositionFrame': 512,
    'underrunStarvedPushedFrames': 512,
    'underrunFinalUnderrunCount': 1,
    'underrunFinalDrainedChecksumHex': '00000000abcdef12',
    'underrunSampleMismatches': 0,
    'staleGenerationPinned': 1,
    'staleCurrentGeneration': 2,
    'staleResultReason': 'stale_generation',
    'stalePinnedIngestStatus': 'ok',
    'stalePinnedOnOwnerThread': true,
    'disposeState': 'DISPOSED',
    'disposeIngestReason': 'disposed',
    'disposePostIngestPosted': false,
    'commandInFlightGateProof': 'source_mechanical_only',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'Y5a realtime playback external ingest seam harness pass=true',
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

VGRealtimePlaybackIngestSeamSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGRealtimePlaybackIngestSeamSmokeReport.fromMap(
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

  group('VGRealtimePlaybackIngestSeamSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.methodName,
        equals('runRealtimePlaybackIngestSeamSmoke'),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.requiredGateKeys.length,
        equals(7),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.requiredGateKeys,
        contains('ingestIdentityOk'),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.requiredGateKeys,
        contains('seekReanchorOk'),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.requiredGateKeys,
        contains('backpressureOk'),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.requiredGateKeys,
        contains('directNativeGuardsOk'),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.requiredGateKeys,
        contains('underrunNonterminalOk'),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.requiredGateKeys,
        contains('staleGenerationOk'),
      );
      expect(
        VGRealtimePlaybackIngestSeamSmokeReport.requiredGateKeys,
        contains('lifecycleDisposeOk'),
      );
    });
  });

  group('VGRealtimePlaybackIngestSeamSmokeReport.fromMap parsing', () {
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
      expect(report.ingestIdentityOk, isTrue);
      expect(report.seekReanchorOk, isTrue);
      expect(report.backpressureOk, isTrue);
      expect(report.directNativeGuardsOk, isTrue);
      expect(report.underrunNonterminalOk, isTrue);
      expect(report.staleGenerationOk, isTrue);
      expect(report.lifecycleDisposeOk, isTrue);
      expect(report.proofBoundaryOk, isTrue);
      expect(report.canonical, isTrue);

      // Verify metrics in metrics map
      expect(report.metrics['identityPrerollFrames'], equals(1024));
      expect(report.metrics['identityIngestCalls'], equals(12));
      expect(report.metrics['identityAcceptedFrames'], equals(12000));
      expect(report.metrics['identityDrainCalls'], equals(48));
      expect(report.metrics['identitySampleMismatches'], equals(0));
      expect(report.metrics['seekFirstIngestOk'], isTrue);
      expect(report.metrics['seekAccepted'], isTrue);
      expect(report.metrics['seekStaleAnchorRejected'], isTrue);
      expect(
        report.metrics['backpressurePartialStatus'],
        equals('partial_write'),
      );
      expect(
        report.metrics['guardWrongOwnerStatus'],
        equals('wrong_owner_thread'),
      );
      expect(report.metrics['underrunStarvedUnderrunCount'], equals(1));
      expect(report.metrics['staleGenerationPinned'], equals(1));
      expect(report.metrics['disposeState'], equals('DISPOSED'));
    });

    test('every required gate false causes isVerifiedPass to fail', () {
      for (final gateKey
          in VGRealtimePlaybackIngestSeamSmokeReport.requiredGateKeys) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes[gateKey] = false;
        raw['lanes'] = lanes;

        final report = VGRealtimePlaybackIngestSeamSmokeReport.fromMap(raw);
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

      final report = VGRealtimePlaybackIngestSeamSmokeReport.fromMap(raw);
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
      final report = VGRealtimePlaybackIngestSeamSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, equals('proof_boundary_mismatch'));
    });

    test('bad marker fails closed', () {
      final raw = _createSampleRawMap({'marker': 'INVALID_MARKER'});
      final report = VGRealtimePlaybackIngestSeamSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('bad status fails closed', () {
      final raw = _createSampleRawMap({'status': 'fail'});
      final report = VGRealtimePlaybackIngestSeamSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
    });

    test('non-empty failureReason fails closed', () {
      final raw = _createSampleRawMap({
        'failureReason': 'seek_reanchor_failed:playing:expected_start_mismatch',
      });
      final report = VGRealtimePlaybackIngestSeamSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals('seek_reanchor_failed:playing:expected_start_mismatch'),
      );
      expect(
        report.lastError,
        equals('seek_reanchor_failed:playing:expected_start_mismatch'),
      );
    });

    test(
      'malformed/non-map MethodChannel payload produces fail-shaped report',
      () {
        final reportNull = VGRealtimePlaybackIngestSeamSmokeReport.fromMap(
          null,
        );
        expect(reportNull.pass, isFalse);
        expect(reportNull.isVerifiedPass, isFalse);
        expect(reportNull.marker, equals(_kFailMarker));
        expect(reportNull.failureReason, equals('native_result_not_a_map'));
        expect(reportNull.lastError, equals('native_result_not_a_map'));
        expect(reportNull.ingestIdentityOk, isFalse);

        final reportString = VGRealtimePlaybackIngestSeamSmokeReport.fromMap(
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
          'ingestIdentityOk': 'true',
          'seekReanchorOk': 'ok',
          'backpressureOk': 'true',
          'directNativeGuardsOk': 'true',
          'underrunNonterminalOk': 'true',
          'staleGenerationOk': 'true',
          'lifecycleDisposeOk': 'true',
          'proofBoundaryOk': 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{'identityPrerollFrames': 1024},
      };

      final report = VGRealtimePlaybackIngestSeamSmokeReport.fromMap(raw);
      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.ingestIdentityOk, isTrue);
      expect(report.seekReanchorOk, isTrue);
      expect(report.metrics['identityPrerollFrames'], equals(1024));
    });

    test('nested lane and metric maps are preserved', () {
      final sample = _createSampleRawMap();
      final report = VGRealtimePlaybackIngestSeamSmokeReport.fromMap(sample);

      expect(report.metrics['identityFinalState'], equals('COMPLETED'));
      expect(report.lanes['ingestIdentityOk'], isTrue);

      final map = report.toMap();
      expect(map['lanes'], isA<Map>());
      expect(map['metrics'], isA<Map>());
      expect(report.toJson(), equals(map));
    });

    test('toString produces diagnostic representation', () {
      final report = _createSampleReport();
      expect(
        report.toString(),
        contains('VGRealtimePlaybackIngestSeamSmokeReport'),
      );
      expect(report.toString(), contains('ingestIdentityOk: true'));
      expect(report.toString(), contains('isVerifiedPass: true'));
    });
  });

  group('VGRealtimePlaybackIngestSeamSmokeReport MethodChannel invocation', () {
    test('method route invoked exactly and returns pass report', () async {
      String? invokedMethod;
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        invokedMethod = call.method;
        if (call.method == 'runRealtimePlaybackIngestSeamSmoke') {
          return _createSampleRawMap();
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackIngestSeamSmokeReport.runRealtimePlaybackIngestSeamSmoke();

      expect(invokedMethod, equals('runRealtimePlaybackIngestSeamSmoke'));
      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('PlatformException produces harness exception report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runRealtimePlaybackIngestSeamSmoke') {
          throw PlatformException(
            code: 'P4_REALTIME_PLAYBACK_INGEST_SEAM_SMOKE_BUSY',
            message: 'Diagnostic already running',
          );
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackIngestSeamSmokeReport.runRealtimePlaybackIngestSeamSmoke();

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_INGEST_SEAM_SMOKE_BUSY',
        ),
      );
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_REALTIME_PLAYBACK_INGEST_SEAM_SMOKE_BUSY:Diagnostic already running',
        ),
      );
    });

    test('TimeoutException produces fallback error report', () async {
      final customChannel = const MethodChannel(
        'vanguard_media_engine_ingest_seam_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });

      final report =
          await VGRealtimePlaybackIngestSeamSmokeReport.runRealtimePlaybackIngestSeamSmoke(
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
