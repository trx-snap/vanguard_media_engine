// vg_audio_scheduler_envelope_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-SCHEDULER-ENVELOPE-WIRING: Android True-DAG Phase 4
// GraphAudioScheduler per-source static-gain/envelope wiring diagnostic smoke foundation
// Dart model and MethodChannel unit tests (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_graph_audio_scheduler_envelope_wiring_diagnostic_only_scheduler_stamps_window_pts_origin_non_owning_per_source_static_gain_and_envelope_params_no_production_mixdown_change_no_export_reroute_no_pass2_reroute_no_runtime_queue_no_backpressure_no_realtime_sink_no_audio_track_no_aaudio_no_opensl_no_oboe_no_media_codec_no_media_extractor_no_file_io_no_native_worker_threads_no_app_no_editor_no_product_no_streaming_no_cache_no_ios';

const _kPassMarker = 'ANDROID_DAG_PHASE4_AUDIO_SCHEDULER_ENVELOPE_SMOKE_PASS';
const _kFailMarker = 'ANDROID_DAG_PHASE4_AUDIO_SCHEDULER_ENVELOPE_SMOKE_FAIL';

const _kSchedulerChecksumWindow0Hex = '0000000011111111';
const _kSchedulerChecksumWindow1Hex = '0000000022222222';
const _kReferenceChecksumWindow0Hex = '0000000011111111';
const _kReferenceChecksumWindow1Hex = '0000000022222222';
const _kUnitGainChecksumWindow0Hex = '0000000033333333';
const _kWrongOriginChecksumWindow1Hex = '0000000044444444';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'schedulerEnvelopeAppliedOk': true,
    'windowPtsOriginOk': true,
    'multiSourceParamsOk': true,
    'nullEnvelopeBackCompatOk': true,
    'mixOutputEnvelopeMetricsPropagatedOk': true,
    'invalidSourceGainFailClosedOk': true,
    'invalidEnvelopeGainFailClosedOk': true,
    'windowPtsOverflowRejectOk': true,
    'staleGenerationFailClosedOk': true,
    'noPerWindowAllocationOk': true,
    'lifecycleOk': true,
    'stackScoped': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'nativeStatus': 'PASS',
    'routedSourceCount': 3,
    'windowFrames': 256,
    'windowPtsUs0': 0,
    'windowPtsUs1': 5333,
    'framesRenderedWindow0': 256,
    'framesRenderedWindow1': 256,
    'envelopeEvaluationsWindow0': 256,
    'envelopeEvaluationsWindow1': 256,
    'sampleRate': 48000,
    'channelCount': 2,
    'maxFramesPerMix': 256,
    'minEffectiveGainWindow0': 0.0,
    'maxEffectiveGainWindow0': 1.0,
    'schedulerChecksumWindow0Hex': _kSchedulerChecksumWindow0Hex,
    'schedulerChecksumWindow1Hex': _kSchedulerChecksumWindow1Hex,
    'referenceChecksumWindow0Hex': _kReferenceChecksumWindow0Hex,
    'referenceChecksumWindow1Hex': _kReferenceChecksumWindow1Hex,
    'unitGainChecksumWindow0Hex': _kUnitGainChecksumWindow0Hex,
    'wrongOriginChecksumWindow1Hex': _kWrongOriginChecksumWindow1Hex,
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'nativeOneShotStackScoped=true|scheduler_owns_window_origin_mix_bus_owns_per_frame_gain_math|no_production_mixdown_or_export_reroute_change',
    'lanes': lanes,
    'metrics': metrics,
    'lastError': null,
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

VGAudioSchedulerEnvelopeSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) =>
    VGAudioSchedulerEnvelopeSmokeReport.fromMap(_createSampleRawMap(overrides));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGAudioSchedulerEnvelopeSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.methodName,
        equals('runAndroidDagPhase4AudioSchedulerEnvelopeSmoke'),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys.length,
        equals(12),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys,
        contains('schedulerEnvelopeAppliedOk'),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys,
        contains('windowPtsOriginOk'),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys,
        contains('multiSourceParamsOk'),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys,
        contains('nullEnvelopeBackCompatOk'),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys,
        contains('mixOutputEnvelopeMetricsPropagatedOk'),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys,
        contains('invalidSourceGainFailClosedOk'),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys,
        contains('invalidEnvelopeGainFailClosedOk'),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys,
        contains('windowPtsOverflowRejectOk'),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys,
        contains('staleGenerationFailClosedOk'),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys,
        contains('noPerWindowAllocationOk'),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys,
        contains('lifecycleOk'),
      );
      expect(
        VGAudioSchedulerEnvelopeSmokeReport.requiredNativeLaneKeys,
        contains('stackScoped'),
      );
    });
  });

  group('VGAudioSchedulerEnvelopeSmokeReport.fromMap parsing', () {
    test('pass payload parses true with all lanes and metrics', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.marker, equals(_kPassMarker));
      expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.lastError, isEmpty);
      expect(report.failureReason, isEmpty);

      // Verify all 13 lanes
      expect(report.schedulerEnvelopeAppliedOk, isTrue);
      expect(report.windowPtsOriginOk, isTrue);
      expect(report.multiSourceParamsOk, isTrue);
      expect(report.nullEnvelopeBackCompatOk, isTrue);
      expect(report.mixOutputEnvelopeMetricsPropagatedOk, isTrue);
      expect(report.invalidSourceGainFailClosedOk, isTrue);
      expect(report.invalidEnvelopeGainFailClosedOk, isTrue);
      expect(report.windowPtsOverflowRejectOk, isTrue);
      expect(report.staleGenerationFailClosedOk, isTrue);
      expect(report.noPerWindowAllocationOk, isTrue);
      expect(report.lifecycleOk, isTrue);
      expect(report.stackScoped, isTrue);
      expect(report.canonical, isTrue);

      // Verify metrics
      expect(report.nativeStatus, equals('PASS'));
      expect(report.routedSourceCount, equals(3));
      expect(report.windowFrames, equals(256));
      expect(report.windowPtsUs0, equals(0));
      expect(report.windowPtsUs1, equals(5333));
      expect(report.framesRenderedWindow0, equals(256));
      expect(report.framesRenderedWindow1, equals(256));
      expect(report.envelopeEvaluationsWindow0, equals(256));
      expect(report.envelopeEvaluationsWindow1, equals(256));
      expect(report.sampleRate, equals(48000));
      expect(report.channelCount, equals(2));
      expect(report.maxFramesPerMix, equals(256));
      expect(report.minEffectiveGainWindow0, equals(0.0));
      expect(report.maxEffectiveGainWindow0, equals(1.0));
      expect(
        report.schedulerChecksumWindow0Hex,
        equals(_kSchedulerChecksumWindow0Hex),
      );
      expect(
        report.schedulerChecksumWindow1Hex,
        equals(_kSchedulerChecksumWindow1Hex),
      );
      expect(
        report.referenceChecksumWindow0Hex,
        equals(_kReferenceChecksumWindow0Hex),
      );
      expect(
        report.referenceChecksumWindow1Hex,
        equals(_kReferenceChecksumWindow1Hex),
      );
      expect(
        report.unitGainChecksumWindow0Hex,
        equals(_kUnitGainChecksumWindow0Hex),
      );
      expect(
        report.wrongOriginChecksumWindow1Hex,
        equals(_kWrongOriginChecksumWindow1Hex),
      );
      expect(report.window0MatchesReference, isTrue);
      expect(report.window1MatchesReference, isTrue);
    });

    test('missing required lane fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes.remove('schedulerEnvelopeAppliedOk');
      raw['lanes'] = lanes;

      final report = VGAudioSchedulerEnvelopeSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_lane'));
      expect(
        report.lastError,
        equals('missing_lane_schedulerEnvelopeAppliedOk'),
      );
    });

    test('proof boundary mismatch fails closed', () {
      final raw = _createSampleRawMap({
        'proofBoundary': 'invalid_proof_boundary_string',
      });
      final report = VGAudioSchedulerEnvelopeSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, equals('proof_boundary_mismatch'));
    });

    test('marker mismatch fails closed', () {
      final raw = _createSampleRawMap({'marker': 'INVALID_MARKER'});
      final report = VGAudioSchedulerEnvelopeSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('pass true with false lane fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes['invalidSourceGainFailClosedOk'] = false;
      raw['lanes'] = lanes;

      final report = VGAudioSchedulerEnvelopeSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.invalidSourceGainFailClosedOk, isFalse);
      expect(report.status, equals('lane_failed'));
      expect(report.lastError, equals('lane_failed'));
    });

    test('native failure payload propagates failure reason', () {
      final raw = _createSampleRawMap({
        'pass': false,
        'status': 'fail',
        'marker': _kFailMarker,
        'failureReason': 'invalid_source_gain_did_not_reject',
      });
      final report = VGAudioSchedulerEnvelopeSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(
        report.failureReason,
        equals('invalid_source_gain_did_not_reject'),
      );
      expect(report.lastError, equals('invalid_source_gain_did_not_reject'));
    });

    test('malformed payload fails closed (non-map)', () {
      final report = VGAudioSchedulerEnvelopeSmokeReport.fromMap(null);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('native_result_not_a_map'));
      expect(report.lastError, equals('native_result_not_a_map'));
      expect(report.schedulerEnvelopeAppliedOk, isFalse);
      expect(report.windowPtsOriginOk, isFalse);
    });

    test('string-encoded and numeric values parse defensively', () {
      final raw = <String, Object?>{
        'pass': 'true',
        'status': 'PASS',
        'marker': _kPassMarker,
        'proofBoundary': _kCanonicalProofBoundary,
        'lanes': <String, Object?>{
          'schedulerEnvelopeAppliedOk': 'true',
          'windowPtsOriginOk': 'true',
          'multiSourceParamsOk': 'true',
          'nullEnvelopeBackCompatOk': 'true',
          'mixOutputEnvelopeMetricsPropagatedOk': 'true',
          'invalidSourceGainFailClosedOk': 'true',
          'invalidEnvelopeGainFailClosedOk': 'true',
          'windowPtsOverflowRejectOk': 'true',
          'staleGenerationFailClosedOk': 'true',
          'noPerWindowAllocationOk': 'true',
          'lifecycleOk': 'true',
          'stackScoped': 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{
          'nativeStatus': 'PASS',
          'routedSourceCount': '3',
          'windowFrames': '256',
          'windowPtsUs0': '0',
          'windowPtsUs1': '5333',
          'framesRenderedWindow0': '256',
          'framesRenderedWindow1': '256',
          'envelopeEvaluationsWindow0': '256',
          'envelopeEvaluationsWindow1': '256',
          'sampleRate': '48000',
          'channelCount': '2',
          'maxFramesPerMix': '256',
          'minEffectiveGainWindow0': '0.0',
          'maxEffectiveGainWindow0': '1.0',
          'schedulerChecksumWindow0Hex': _kSchedulerChecksumWindow0Hex,
          'schedulerChecksumWindow1Hex': _kSchedulerChecksumWindow1Hex,
          'referenceChecksumWindow0Hex': _kReferenceChecksumWindow0Hex,
          'referenceChecksumWindow1Hex': _kReferenceChecksumWindow1Hex,
          'unitGainChecksumWindow0Hex': _kUnitGainChecksumWindow0Hex,
          'wrongOriginChecksumWindow1Hex': _kWrongOriginChecksumWindow1Hex,
        },
      };

      final report = VGAudioSchedulerEnvelopeSmokeReport.fromMap(raw);
      expect(report.pass, isTrue);
      expect(report.routedSourceCount, equals(3));
      expect(report.windowFrames, equals(256));
      expect(report.windowPtsUs1, equals(5333));
      expect(report.sampleRate, equals(48000));
      expect(report.channelCount, equals(2));
      expect(report.minEffectiveGainWindow0, equals(0.0));
      expect(report.maxEffectiveGainWindow0, equals(1.0));
    });

    test('toMap serialization preserves structure', () {
      final report = _createSampleReport();
      final map = report.toMap();

      expect(map['pass'], isTrue);
      expect(map['status'], equals('pass'));
      expect(map['marker'], equals(_kPassMarker));
      expect(map['proofBoundary'], equals(_kCanonicalProofBoundary));
      expect(map['lanes'], isA<Map>());
      expect(map['metrics'], isA<Map>());
    });

    test('equality, hashCode, and toString work correctly', () {
      final report1 = _createSampleReport();
      final report2 = _createSampleReport();
      final report3 = _createSampleReport({'routedSourceCount': 2});

      expect(report1, equals(report2));
      expect(report1.hashCode, equals(report2.hashCode));
      expect(report1, isNot(equals(report3)));
      expect(
        report1.toString(),
        contains('VGAudioSchedulerEnvelopeSmokeReport'),
      );
      expect(report1.toString(), contains('schedulerEnvelopeAppliedOk: true'));
    });
  });

  group('VGAudioSchedulerEnvelopeSmokeReport MethodChannel invocation', () {
    test('successful channel invocation returns report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runAndroidDagPhase4AudioSchedulerEnvelopeSmoke') {
          return _createSampleRawMap();
        }
        return null;
      });

      final report =
          await VGAudioSchedulerEnvelopeSmokeReport.runAndroidDagPhase4AudioSchedulerEnvelopeSmoke();

      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('PlatformException produces fallback error report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runAndroidDagPhase4AudioSchedulerEnvelopeSmoke') {
          throw PlatformException(
            code: 'UNAVAILABLE',
            message: 'Native method not registered',
          );
        }
        return null;
      });

      final report =
          await VGAudioSchedulerEnvelopeSmokeReport.runAndroidDagPhase4AudioSchedulerEnvelopeSmoke();

      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('platform_exception:UNAVAILABLE'));
      expect(
        report.lastError,
        contains('platform_exception:UNAVAILABLE:Native method not registered'),
      );
    });

    test('TimeoutException produces fallback error report', () async {
      final customChannel = const MethodChannel(
        'vanguard_media_engine_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });

      final report =
          await VGAudioSchedulerEnvelopeSmokeReport.runAndroidDagPhase4AudioSchedulerEnvelopeSmoke(
            timeout: const Duration(milliseconds: 10),
            channel: customChannel,
          );

      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('timeout'));
      expect(report.lastError, contains('timeout:'));
    });
  });
}
