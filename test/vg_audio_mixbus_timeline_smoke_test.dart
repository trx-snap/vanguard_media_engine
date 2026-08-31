// vg_audio_mixbus_timeline_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP: Android True-DAG Phase 4
// AudioMixBusNode timeline-aware per-frame volume envelope diagnostic smoke foundation
// Dart model and MethodChannel unit tests (under P4-AUDIO-MIXBUS).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_audio_mix_bus_per_frame_volume_envelope_diagnostic_only_linear_interpolation_only_kotlin_android_audio_volume_envelope_parity_normalize_static_fade_and_evaluate_ported_to_cpp_node_owns_gain_math_caller_owns_window_origin_no_scheduler_wiring_no_production_mixdown_change_no_export_reroute_no_pass2_reroute_no_runtime_queue_no_backpressure_no_realtime_sink_no_threads_no_audio_track_no_aaudio_no_media_codec_no_file_io_no_streaming_no_cache_no_ios_no_product_no_editor_no_connects_app';

const _kPassMarker = 'ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_SMOKE_PASS';
const _kFailMarker = 'ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_SMOKE_FAIL';

const _kStaticGainChecksumHex = '00000000aaaaaaaa';
const _kEnvelopeMixChecksumHex = '00000000bbbbbbbb';
const _kNullEnvelopeChecksumHex = '00000000cccccccc';
const _kBaselineStaticChecksumHex = '00000000cccccccc';
const _kPrescaleApproxChecksumHex = '00000000dddddddd';
const _kSingleQuantChecksumHex = '00000000eeeeeeee';
const _kRoundPtsChecksumHex = '00000000ffffffff';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'envelopeNormalizationParityOk': true,
    'envelopeStaticFadePathParityOk': true,
    'envelopeForTrackFallbackParityOk': true,
    'envelopeEvaluationParityOk': true,
    'emptyEnvelopeSilenceParityOk': true,
    'subMillisecondHoldOk': true,
    'boundaryInclusivityOk': true,
    'mixGainNormalizationOk': true,
    'perFrameEnvelopeAppliedOk': true,
    'staticGainCompositionOk': true,
    'nullEnvelopeBackCompatOk': true,
    'singleQuantizationOk': true,
    'envelopeCursorMonotonicOk': true,
    'envelopeCursorResetPerCallOk': true,
    'floorPtsDerivationOk': true,
    'unsupportedInterpolationRejectOk': true,
    'keyframeCapRejectOk': true,
    'invalidEnvelopeRangeRejectOk': true,
    'invalidEnvelopeStartPtsRejectOk': true,
    'invalidEnvelopeGainRejectOk': true,
    'noPerMixAllocationOk': true,
    'schedulerUnchangedOk': true,
    'productionMixdownUntouchedOk': true,
    'lifecycleOk': true,
    'stackScoped': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'normalizedKeyframeCount': 4,
    'staticFadeKeyframeCount': 4,
    'evaluationSampleCount': 2000,
    'maxGainDiffScaled': 0,
    'envelopeEvaluations': 2000,
    'framesMixed': 28800,
    'sampleRate': 48000,
    'channelCount': 2,
    'maxFramesPerMix': 256,
    'minEffectiveGain': 0.0,
    'maxEffectiveGain': 1.0,
    'staticGainChecksumHex': _kStaticGainChecksumHex,
    'envelopeMixChecksumHex': _kEnvelopeMixChecksumHex,
    'nullEnvelopeChecksumHex': _kNullEnvelopeChecksumHex,
    'baselineStaticChecksumHex': _kBaselineStaticChecksumHex,
    'prescaleApproxChecksumHex': _kPrescaleApproxChecksumHex,
    'singleQuantChecksumHex': _kSingleQuantChecksumHex,
    'roundPtsChecksumHex': _kRoundPtsChecksumHex,
    'envelopeGainRejectVia': 'invalid_envelope_gain',
    'timelineOwnershipHonesty':
        'native_timeline_ownership_is_p0_prerequisite_for_production_graph_reroute',
  };

  final raw = <String, String>{
    'status': 'PASS',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'nativeOneShotStackScoped=true|timeline_ownership_is_p0_prerequisite_for_production_graph_reroute_not_runtime_queue_blocker|scheduler_and_production_mixdown_lanes_are_source_level_honesty_lanes',
    'envelopeNormalizationParityOk': 'true',
    'envelopeStaticFadePathParityOk': 'true',
    'envelopeForTrackFallbackParityOk': 'true',
    'envelopeEvaluationParityOk': 'true',
    'emptyEnvelopeSilenceParityOk': 'true',
    'subMillisecondHoldOk': 'true',
    'boundaryInclusivityOk': 'true',
    'mixGainNormalizationOk': 'true',
    'perFrameEnvelopeAppliedOk': 'true',
    'staticGainCompositionOk': 'true',
    'nullEnvelopeBackCompatOk': 'true',
    'singleQuantizationOk': 'true',
    'envelopeCursorMonotonicOk': 'true',
    'envelopeCursorResetPerCallOk': 'true',
    'floorPtsDerivationOk': 'true',
    'unsupportedInterpolationRejectOk': 'true',
    'keyframeCapRejectOk': 'true',
    'invalidEnvelopeRangeRejectOk': 'true',
    'invalidEnvelopeStartPtsRejectOk': 'true',
    'invalidEnvelopeGainRejectOk': 'true',
    'noPerMixAllocationOk': 'true',
    'schedulerUnchangedOk': 'true',
    'productionMixdownUntouchedOk': 'true',
    'lifecycleOk': 'true',
    'stackScoped': 'true',
    'canonical': 'true',
    'normalizedKeyframeCount': '4',
    'staticFadeKeyframeCount': '4',
    'evaluationSampleCount': '2000',
    'maxGainDiffScaled': '0',
    'envelopeEvaluations': '2000',
    'framesMixed': '28800',
    'sampleRate': '48000',
    'channelCount': '2',
    'maxFramesPerMix': '256',
    'minEffectiveGain': '0.0',
    'maxEffectiveGain': '1.0',
    'staticGainChecksumHex': _kStaticGainChecksumHex,
    'envelopeMixChecksumHex': _kEnvelopeMixChecksumHex,
    'nullEnvelopeChecksumHex': _kNullEnvelopeChecksumHex,
    'baselineStaticChecksumHex': _kBaselineStaticChecksumHex,
    'prescaleApproxChecksumHex': _kPrescaleApproxChecksumHex,
    'singleQuantChecksumHex': _kSingleQuantChecksumHex,
    'roundPtsChecksumHex': _kRoundPtsChecksumHex,
    'envelopeGainRejectVia': 'invalid_envelope_gain',
    'timelineOwnershipHonesty':
        'native_timeline_ownership_is_p0_prerequisite_for_production_graph_reroute',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'nativeOneShotStackScoped=true|timeline_ownership_is_p0_prerequisite_for_production_graph_reroute_not_runtime_queue_blocker|scheduler_and_production_mixdown_lanes_are_source_level_honesty_lanes',
    'lanes': lanes,
    'metrics': metrics,
    'raw': raw,
    'lastError': '',
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

VGAudioMixBusTimelineSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGAudioMixBusTimelineSmokeReport.fromMap(_createSampleRawMap(overrides));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGAudioMixBusTimelineSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGAudioMixBusTimelineSmokeReport.methodName,
        equals('runAndroidDagPhase4AudioMixBusTimelineSmoke'),
      );
      expect(
        VGAudioMixBusTimelineSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGAudioMixBusTimelineSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGAudioMixBusTimelineSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGAudioMixBusTimelineSmokeReport.minEvaluationSamples,
        equals(2000),
      );
      expect(
        VGAudioMixBusTimelineSmokeReport.maxGainDiffScaledBound,
        equals(1000000),
      );
      expect(
        VGAudioMixBusTimelineSmokeReport.expectedSampleRate,
        equals(48000),
      );
      expect(VGAudioMixBusTimelineSmokeReport.expectedChannelCount, equals(2));
      expect(
        VGAudioMixBusTimelineSmokeReport.requiredNativeLaneKeys.length,
        equals(25),
      );
    });
  });

  group('VGAudioMixBusTimelineSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGAudioMixBusTimelineSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.status, equals('pass'));
        expect(report.marker, equals(_kPassMarker));
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.hasPassMarker, isTrue);
        expect(report.hasFailMarker, isFalse);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.failureReason, isEmpty);
        expect(report.lastError, isEmpty);
        expect(report.details, contains('nativeOneShotStackScoped=true'));

        // Lanes (26 lanes)
        expect(report.envelopeNormalizationParityOk, isTrue);
        expect(report.envelopeStaticFadePathParityOk, isTrue);
        expect(report.envelopeForTrackFallbackParityOk, isTrue);
        expect(report.envelopeEvaluationParityOk, isTrue);
        expect(report.emptyEnvelopeSilenceParityOk, isTrue);
        expect(report.subMillisecondHoldOk, isTrue);
        expect(report.boundaryInclusivityOk, isTrue);
        expect(report.mixGainNormalizationOk, isTrue);
        expect(report.perFrameEnvelopeAppliedOk, isTrue);
        expect(report.staticGainCompositionOk, isTrue);
        expect(report.nullEnvelopeBackCompatOk, isTrue);
        expect(report.singleQuantizationOk, isTrue);
        expect(report.envelopeCursorMonotonicOk, isTrue);
        expect(report.envelopeCursorResetPerCallOk, isTrue);
        expect(report.floorPtsDerivationOk, isTrue);
        expect(report.unsupportedInterpolationRejectOk, isTrue);
        expect(report.keyframeCapRejectOk, isTrue);
        expect(report.invalidEnvelopeRangeRejectOk, isTrue);
        expect(report.invalidEnvelopeStartPtsRejectOk, isTrue);
        expect(report.invalidEnvelopeGainRejectOk, isTrue);
        expect(report.noPerMixAllocationOk, isTrue);
        expect(report.schedulerUnchangedOk, isTrue);
        expect(report.productionMixdownUntouchedOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.stackScoped, isTrue);
        expect(report.canonical, isTrue);

        // Metrics (20 metrics)
        expect(report.normalizedKeyframeCount, equals(4));
        expect(report.staticFadeKeyframeCount, equals(4));
        expect(report.evaluationSampleCount, equals(2000));
        expect(report.maxGainDiffScaled, equals(0));
        expect(report.envelopeEvaluations, equals(2000));
        expect(report.framesMixed, equals(28800));
        expect(report.sampleRate, equals(48000));
        expect(report.channelCount, equals(2));
        expect(report.maxFramesPerMix, equals(256));
        expect(report.minEffectiveGain, equals(0.0));
        expect(report.maxEffectiveGain, equals(1.0));
        expect(report.staticGainChecksumHex, equals(_kStaticGainChecksumHex));
        expect(report.envelopeMixChecksumHex, equals(_kEnvelopeMixChecksumHex));
        expect(
          report.nullEnvelopeChecksumHex,
          equals(_kNullEnvelopeChecksumHex),
        );
        expect(
          report.baselineStaticChecksumHex,
          equals(_kBaselineStaticChecksumHex),
        );
        expect(
          report.prescaleApproxChecksumHex,
          equals(_kPrescaleApproxChecksumHex),
        );
        expect(report.singleQuantChecksumHex, equals(_kSingleQuantChecksumHex));
        expect(report.roundPtsChecksumHex, equals(_kRoundPtsChecksumHex));
        expect(report.envelopeGainRejectVia, equals('invalid_envelope_gain'));
        expect(report.timelineOwnershipHonesty, contains('p0_prerequisite'));

        // Derived getters
        expect(report.nullEnvelopeMatchesBaseline, isTrue);
        expect(report.analyticBoundsPass, isTrue);
        expect(report.gainBoundsPass, isTrue);
        expect(report.audioFormatPass, isTrue);
        expect(report.allNativeLanesPass, isTrue);

        // Serialization & round trip
        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['status'], equals('pass'));
        expect(serialized['marker'], equals(_kPassMarker));
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(serialized['lastError'], equals(''));
        expect(serialized['lanes'], equals(report.lanes));
        expect(serialized['metrics'], equals(report.metrics));
        expect(serialized['raw'], equals(report.raw));

        final roundTrip = VGAudioMixBusTimelineSmokeReport.fromMap(serialized);
        expect(roundTrip, equals(report));
        expect(roundTrip.hashCode, equals(report.hashCode));
        expect(report.toString(), contains('VGAudioMixBusTimelineSmokeReport'));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAudioMixBusTimelineSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'status': 'invalid_envelope_gain',
          'marker': _kFailMarker,
          'failureReason': 'invalid_envelope_gain',
          'lastError': 'invalid_envelope_gain',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.status, equals('invalid_envelope_gain'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.hasPassMarker, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.failureReason, equals('invalid_envelope_gain'));
      expect(report.lastError, equals('invalid_envelope_gain'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a', 'b'],
      ]) {
        final report = VGAudioMixBusTimelineSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
        expect(report.proofBoundary, isEmpty);
        expect(report.status, equals('fail'));
        expect(report.marker, equals(_kFailMarker));
        expect(
          report.raw,
          equals(const <String, String>{'reason': 'native_result_not_a_map'}),
        );
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.allNativeLanesPass, isFalse);
        expect(report.evaluationSampleCount, equals(0));
        expect(report.framesMixed, equals(0));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGAudioMixBusTimelineSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'marker=$_kPassMarker;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'envelopeNormalizationParityOk=true;'
            'envelopeStaticFadePathParityOk=true;'
            'envelopeForTrackFallbackParityOk=true;'
            'envelopeEvaluationParityOk=true;'
            'emptyEnvelopeSilenceParityOk=true;'
            'subMillisecondHoldOk=true;'
            'boundaryInclusivityOk=true;'
            'mixGainNormalizationOk=true;'
            'perFrameEnvelopeAppliedOk=true;'
            'staticGainCompositionOk=true;'
            'nullEnvelopeBackCompatOk=true;'
            'singleQuantizationOk=true;'
            'envelopeCursorMonotonicOk=true;'
            'envelopeCursorResetPerCallOk=true;'
            'floorPtsDerivationOk=true;'
            'unsupportedInterpolationRejectOk=true;'
            'keyframeCapRejectOk=true;'
            'invalidEnvelopeRangeRejectOk=true;'
            'invalidEnvelopeStartPtsRejectOk=true;'
            'invalidEnvelopeGainRejectOk=true;'
            'noPerMixAllocationOk=true;'
            'schedulerUnchangedOk=true;'
            'productionMixdownUntouchedOk=true;'
            'lifecycleOk=true;'
            'stackScoped=true;'
            'canonical=true;'
            'normalizedKeyframeCount=4;'
            'staticFadeKeyframeCount=4;'
            'evaluationSampleCount=2000;'
            'maxGainDiffScaled=0;'
            'envelopeEvaluations=2000;'
            'framesMixed=28800;'
            'sampleRate=48000;'
            'channelCount=2;'
            'maxFramesPerMix=256;'
            'minEffectiveGain=0.0;'
            'maxEffectiveGain=1.0;'
            'staticGainChecksumHex=$_kStaticGainChecksumHex;'
            'envelopeMixChecksumHex=$_kEnvelopeMixChecksumHex;'
            'nullEnvelopeChecksumHex=$_kNullEnvelopeChecksumHex;'
            'baselineStaticChecksumHex=$_kBaselineStaticChecksumHex;'
            'prescaleApproxChecksumHex=$_kPrescaleApproxChecksumHex;'
            'singleQuantChecksumHex=$_kSingleQuantChecksumHex;'
            'roundPtsChecksumHex=$_kRoundPtsChecksumHex;'
            'envelopeGainRejectVia=invalid_envelope_gain;'
            'timelineOwnershipHonesty=native_timeline_ownership_is_p0_prerequisite',
        'lanes': const <String, Object?>{},
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.envelopeNormalizationParityOk, isTrue);
      expect(reportFromRaw.envelopeEvaluationParityOk, isTrue);
      expect(reportFromRaw.perFrameEnvelopeAppliedOk, isTrue);
      expect(reportFromRaw.nullEnvelopeBackCompatOk, isTrue);
      expect(reportFromRaw.singleQuantizationOk, isTrue);
      expect(reportFromRaw.evaluationSampleCount, equals(2000));
      expect(reportFromRaw.sampleRate, equals(48000));
      expect(reportFromRaw.channelCount, equals(2));
      expect(reportFromRaw.framesMixed, equals(28800));
      expect(reportFromRaw.nullEnvelopeMatchesBaseline, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in lanes and metrics', () {
      final report = VGAudioMixBusTimelineSmokeReport.fromMap({
        'pass': 'true',
        'status': 'pass',
        'marker': _kPassMarker,
        'proofBoundary': _kCanonicalProofBoundary,
        'evaluationSampleCount': '2000',
        'maxGainDiffScaled': '0',
        'framesMixed': '28800',
        'sampleRate': '48000',
        'channelCount': '2',
        'minEffectiveGain': '0.0',
        'maxEffectiveGain': '1.0',
        'nullEnvelopeChecksumHex': _kNullEnvelopeChecksumHex,
        'baselineStaticChecksumHex': _kBaselineStaticChecksumHex,
        'lanes': const <String, Object?>{
          'envelopeNormalizationParityOk': 'true',
          'envelopeStaticFadePathParityOk': 'pass',
          'envelopeForTrackFallbackParityOk': 'ok',
          'envelopeEvaluationParityOk': 'success',
          'emptyEnvelopeSilenceParityOk': 'true',
          'subMillisecondHoldOk': 'true',
          'boundaryInclusivityOk': 'true',
          'mixGainNormalizationOk': 'true',
          'perFrameEnvelopeAppliedOk': 'true',
          'staticGainCompositionOk': 'true',
          'nullEnvelopeBackCompatOk': 'true',
          'singleQuantizationOk': 'true',
          'envelopeCursorMonotonicOk': 'true',
          'envelopeCursorResetPerCallOk': 'true',
          'floorPtsDerivationOk': 'true',
          'unsupportedInterpolationRejectOk': 'true',
          'keyframeCapRejectOk': 'true',
          'invalidEnvelopeRangeRejectOk': 'true',
          'invalidEnvelopeStartPtsRejectOk': 'true',
          'invalidEnvelopeGainRejectOk': 'true',
          'noPerMixAllocationOk': 'true',
          'schedulerUnchangedOk': 'true',
          'productionMixdownUntouchedOk': 'true',
          'lifecycleOk': 'true',
          'stackScoped': 'true',
          'canonical': 'true',
        },
      });

      expect(report.pass, isTrue);
      expect(report.envelopeNormalizationParityOk, isTrue);
      expect(report.envelopeStaticFadePathParityOk, isTrue);
      expect(report.envelopeForTrackFallbackParityOk, isTrue);
      expect(report.envelopeEvaluationParityOk, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('nested lane and metric precedence over top-level or raw fields', () {
      final report = VGAudioMixBusTimelineSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'envelopeNormalizationParityOk': false,
        'sampleRate': 22050,
        'lanes': const <String, Object?>{'envelopeNormalizationParityOk': true},
        'metrics': const <String, Object?>{'sampleRate': 48000},
        'raw': const <String, String>{
          'envelopeNormalizationParityOk': 'false',
          'sampleRate': '44100',
        },
      });

      expect(report.envelopeNormalizationParityOk, isTrue);
      expect(report.sampleRate, equals(48000));
    });
  });

  group('Proof boundary validation', () {
    test('proof boundary validation strictly checks canonical string', () {
      final reportValid = _createSampleReport();
      expect(reportValid.hasCanonicalProofBoundary, isTrue);
      expect(reportValid.allNativeLanesPass, isTrue);

      final reportInvalid = _createSampleReport({
        'proofBoundary': 'invalid_proof_boundary_string',
      });
      expect(reportInvalid.hasCanonicalProofBoundary, isFalse);
      expect(reportInvalid.pass, isFalse);
      expect(reportInvalid.allNativeLanesPass, isFalse);
      expect(reportInvalid.lastError, equals('proof_boundary_mismatch'));

      final reportEmpty = _createSampleReport({'proofBoundary': ''});
      expect(reportEmpty.hasCanonicalProofBoundary, isFalse);
      expect(reportEmpty.pass, isFalse);
      expect(reportEmpty.allNativeLanesPass, isFalse);
    });
  });

  group('Lane fail-closed checks', () {
    test(
      'missing any required native lane causes pass: false and fail-closed',
      () {
        for (final laneKey
            in VGAudioMixBusTimelineSmokeReport.requiredNativeLaneKeys) {
          final rawMap = _createSampleRawMap();
          (rawMap['lanes'] as Map<String, Object?>).remove(laneKey);
          (rawMap['raw'] as Map<String, String>).remove(laneKey);
          rawMap.remove(laneKey);

          final report = VGAudioMixBusTimelineSmokeReport.fromMap(rawMap);
          expect(
            report.pass,
            isFalse,
            reason: 'Expected missing $laneKey to fail',
          );
          expect(report.allNativeLanesPass, isFalse);
          expect(report.marker, equals(_kFailMarker));
          expect(report.lastError, equals('missing_lane_$laneKey'));
        }
      },
    );

    test(
      'false in any required native lane causes pass: false and fail-closed',
      () {
        for (final laneKey
            in VGAudioMixBusTimelineSmokeReport.requiredNativeLaneKeys) {
          final report = _createSampleReport({laneKey: false});
          expect(
            report.pass,
            isFalse,
            reason: 'Expected false in $laneKey to fail',
          );
          expect(report.allNativeLanesPass, isFalse);
          expect(report.marker, equals(_kFailMarker));
        }
      },
    );

    test('false canonical causes pass: false', () {
      final report = _createSampleReport({'canonical': false});
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });
  });

  group('Analytic bounds and format validation', () {
    test('evaluationSampleCount below 2000 fails closed', () {
      final report = _createSampleReport({'evaluationSampleCount': 1999});
      expect(report.analyticBoundsPass, isFalse);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, equals('evaluation_sample_count_below_minimum'));
    });

    test('maxGainDiffScaled above 1000000 fails closed', () {
      final report = _createSampleReport({'maxGainDiffScaled': 1000001});
      expect(report.analyticBoundsPass, isFalse);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, equals('analytic_parity_bound_exceeded'));
    });

    test('negative maxGainDiffScaled fails closed', () {
      final report = _createSampleReport({'maxGainDiffScaled': -1});
      expect(report.analyticBoundsPass, isFalse);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('framesMixed <= 0 fails closed', () {
      final report = _createSampleReport({'framesMixed': 0});
      expect(report.audioFormatPass, isFalse);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, equals('no_frames_mixed'));
    });

    test('invalid sampleRate or channelCount fails closed', () {
      final reportRate = _createSampleReport({'sampleRate': 44100});
      expect(reportRate.audioFormatPass, isFalse);
      expect(reportRate.pass, isFalse);
      expect(reportRate.allNativeLanesPass, isFalse);
      expect(reportRate.lastError, equals('invalid_audio_format'));

      final reportChan = _createSampleReport({'channelCount': 1});
      expect(reportChan.audioFormatPass, isFalse);
      expect(reportChan.pass, isFalse);
      expect(reportChan.allNativeLanesPass, isFalse);
      expect(reportChan.lastError, equals('invalid_audio_format'));
    });

    test('gain bounds out of [0.0, 1.0] fail closed', () {
      final reportMinNeg = _createSampleReport({'minEffectiveGain': -0.01});
      expect(reportMinNeg.gainBoundsPass, isFalse);
      expect(reportMinNeg.pass, isFalse);
      expect(reportMinNeg.allNativeLanesPass, isFalse);
      expect(reportMinNeg.lastError, equals('gain_bounds_exceeded'));

      final reportMaxOver = _createSampleReport({'maxEffectiveGain': 1.05});
      expect(reportMaxOver.gainBoundsPass, isFalse);
      expect(reportMaxOver.pass, isFalse);
      expect(reportMaxOver.allNativeLanesPass, isFalse);
      expect(reportMaxOver.lastError, equals('gain_bounds_exceeded'));

      final reportInverted = _createSampleReport({
        'minEffectiveGain': 0.8,
        'maxEffectiveGain': 0.2,
      });
      expect(reportInverted.gainBoundsPass, isFalse);
      expect(reportInverted.pass, isFalse);
      expect(reportInverted.allNativeLanesPass, isFalse);
      expect(reportInverted.lastError, equals('gain_bounds_exceeded'));
    });
  });

  group('Checksum match validation', () {
    test(
      'null envelope checksum mismatch with baseline static fails closed',
      () {
        final report = _createSampleReport({
          'nullEnvelopeChecksumHex': '0000000011111111',
          'baselineStaticChecksumHex': '0000000022222222',
        });
        expect(report.nullEnvelopeMatchesBaseline, isFalse);
        expect(report.pass, isFalse);
        expect(report.allNativeLanesPass, isFalse);
        expect(report.lastError, equals('null_envelope_checksum_mismatch'));
      },
    );

    test('empty null envelope or baseline checksum fails closed', () {
      final reportEmptyNull = _createSampleReport({
        'nullEnvelopeChecksumHex': '',
      });
      expect(reportEmptyNull.nullEnvelopeMatchesBaseline, isFalse);
      expect(reportEmptyNull.pass, isFalse);
      expect(reportEmptyNull.allNativeLanesPass, isFalse);

      final reportEmptyBaseline = _createSampleReport({
        'baselineStaticChecksumHex': '',
      });
      expect(reportEmptyBaseline.nullEnvelopeMatchesBaseline, isFalse);
      expect(reportEmptyBaseline.pass, isFalse);
      expect(reportEmptyBaseline.allNativeLanesPass, isFalse);
    });
  });

  group('MethodChannel invocation', () {
    test('successful channel invocation returns passing report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        expect(
          call.method,
          equals('runAndroidDagPhase4AudioMixBusTimelineSmoke'),
        );
        expect(call.arguments, isNull);
        return _createSampleRawMap();
      });

      final report =
          await VGAudioMixBusTimelineSmokeReport.runAndroidDagPhase4AudioMixBusTimelineSmoke();

      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('injected MethodChannel works correctly', () async {
      const customChannel = MethodChannel('custom_media_engine');
      binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
        expect(
          call.method,
          equals('runAndroidDagPhase4AudioMixBusTimelineSmoke'),
        );
        return _createSampleRawMap();
      });

      final report =
          await VGAudioMixBusTimelineSmokeReport.runAndroidDagPhase4AudioMixBusTimelineSmoke(
            channel: customChannel,
          );

      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('PlatformException produces error fallback report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw PlatformException(
          code: 'UNAVAILABLE',
          message: 'Diagnostic native method failed',
        );
      });

      final report =
          await VGAudioMixBusTimelineSmokeReport.runAndroidDagPhase4AudioMixBusTimelineSmoke();

      expect(report.pass, isFalse);
      expect(report.status, equals('fail'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('platform_exception:UNAVAILABLE'));
      expect(report.details, equals('Diagnostic native method failed'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('Timeout produces error fallback report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return _createSampleRawMap();
      });

      final report =
          await VGAudioMixBusTimelineSmokeReport.runAndroidDagPhase4AudioMixBusTimelineSmoke(
            timeout: const Duration(milliseconds: 10),
          );

      expect(report.pass, isFalse);
      expect(report.status, equals('fail'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('timeout'));
      expect(report.lastError, contains('timeout'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('generic exception produces error fallback report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw Exception('Native crash simulated');
      });

      final report =
          await VGAudioMixBusTimelineSmokeReport.runAndroidDagPhase4AudioMixBusTimelineSmoke();

      expect(report.pass, isFalse);
      expect(report.status, equals('fail'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, contains('exception:'));
      expect(report.allNativeLanesPass, isFalse);
    });
  });
}
