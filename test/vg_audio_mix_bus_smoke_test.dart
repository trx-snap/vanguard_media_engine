// vg_audio_mix_bus_smoke_test.dart
// vanguard_media_engine — P4-AUDIO-MIXBUS: Android True-DAG Phase 4
// AudioMixBusNode PCM16 mix-math diagnostic smoke Dart model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_audio_mix_bus_node_pcm16_mix_math_only_no_decoder_no_aac_no_export_no_realtime_no_playback_no_product';

const _kAllLanes = <String>[
  'topologyPorts',
  'stereoStereoDeterministic',
  'monoToStereoUpmix',
  'stereoToMonoDownmix',
  'positiveSaturation',
  'negativeSaturation',
  'oddSampleTruncation',
  'negativeDownmixDivision',
  'shorterTrackSilence',
  'longerTrackShortWindowMix',
  'fourTrackDeterministicMix',
  'noPrematureClip',
  'finalSaturation',
  'eightTrackCapacity',
  'invalidGainRejection',
  'nonFiniteGainRejection',
  'sampleRateMismatchRejection',
  'invalidTrackChannelCountRejection',
  'insufficientOutputCapacityRejection',
  'invalidSessionRejection',
  'nineTrackReject',
  'destroyIdempotent',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final metrics = <String, Object?>{
    'topologyPorts.pass': true,
    'stereoStereoDeterministic.pass': true,
    'monoToStereoUpmix.pass': true,
    'stereoToMonoDownmix.pass': true,
    'positiveSaturation.pass': true,
    'negativeSaturation.pass': true,
    'oddSampleTruncation.pass': true,
    'negativeDownmixDivision.pass': true,
    'shorterTrackSilence.pass': true,
    'longerTrackShortWindowMix.pass': true,
    'fourTrackDeterministicMix.pass': true,
    'noPrematureClip.pass': true,
    'finalSaturation.pass': true,
    'eightTrackCapacity.pass': true,
    'invalidGainRejection.pass': true,
    'nonFiniteGainRejection.pass': true,
    'sampleRateMismatchRejection.pass': true,
    'invalidTrackChannelCountRejection.pass': true,
    'insufficientOutputCapacityRejection.pass': true,
    'invalidSessionRejection.pass': true,
    'nineTrackReject.pass': true,
    'destroyIdempotent.pass': true,
    'laneCount': 22,
    'lanePassCount': 22,
  };

  final raw = <String, String>{
    'topologyPorts.create': 'status=PASS;kind=processing;type=audio_mix_bus',
    'topologyPorts.destroy': 'status=PASS',
    'stereoStereoDeterministic.create': 'status=PASS',
    'stereoStereoDeterministic.add0': 'status=PASS',
    'stereoStereoDeterministic.add1': 'status=PASS',
    'stereoStereoDeterministic.mix': 'status=PASS;checksum=12345;clipped=false',
    'stereoStereoDeterministic.destroy': 'status=PASS',
    'monoToStereoUpmix.mix': 'status=PASS;checksum=23456;clipped=false',
    'stereoToMonoDownmix.mix': 'status=PASS;checksum=34567;clipped=false',
    'positiveSaturation.mix': 'status=PASS;checksum=45678;clipped=true',
    'negativeSaturation.mix': 'status=PASS;checksum=56789;clipped=true',
    'oddSampleTruncation.mix': 'status=PASS;checksum=67890;clipped=false',
    'negativeDownmixDivision.mix': 'status=PASS;checksum=78901;clipped=false',
    'shorterTrackSilence.mix': 'status=PASS;checksum=89012;clipped=false',
    'longerTrackShortWindowMix.mix': 'status=PASS;checksum=90123;clipped=false',
    'fourTrackDeterministicMix.mix': 'status=PASS;checksum=11111;clipped=false',
    'noPrematureClip.mix': 'status=PASS;checksum=22222;clipped=false',
    'finalSaturation.mix': 'status=PASS;checksum=33333;clipped=true',
    'eightTrackCapacity.mix': 'status=PASS;checksum=44444;clipped=false',
    'invalidGainRejection.mix': 'status=FAIL;reason=invalid_gain',
    'nonFiniteGainRejection.mix': 'status=FAIL;reason=invalid_gain',
    'sampleRateMismatchRejection.mix':
        'status=FAIL;reason=sample_rate_mismatch',
    'invalidTrackChannelCountRejection.add0':
        'status=FAIL;reason=invalid_channel_count',
    'invalidTrackChannelCountRejection.mix': 'not_run_after_add_rejection',
    'invalidTrackChannelCountRejection.destroy': 'status=PASS',
    'insufficientOutputCapacityRejection.mix':
        'status=FAIL;reason=insufficient_output_capacity',
    'invalidSessionRejection.add': 'status=FAIL;reason=session_not_found',
    'invalidSessionRejection.mix': 'status=FAIL;reason=session_not_found',
    'nineTrackReject.add8': 'status=FAIL;reason=track_limit_exceeded',
    'nineTrackReject.destroy': 'status=PASS',
    'destroyIdempotent.destroy1': 'status=PASS',
    'destroyIdempotent.destroy2': 'status=FAIL;reason=session_not_found',
  };

  return <String, Object?>{
    'pass': true,
    'proofBoundary': _kCanonicalProofBoundary,
    'raw': raw,
    'metrics': metrics,
    'lastError': 'none',
    if (overrides != null) ...overrides,
  };
}

VGAudioMixBusSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGAudioMixBusSmokeReport.fromMap(_createSampleRawMap(overrides));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGAudioMixBusSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all 22 lanes and fields cleanly',
      () {
        final report = VGAudioMixBusSmokeReport.fromMap(_createSampleRawMap());

        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.lastError, equals('none'));
        expect(report.laneCount, equals(22));
        expect(report.lanePassCount, equals(22));

        // Math lanes
        expect(report.stereoStereoDeterministic, isTrue);
        expect(report.stereoStereoDeterministicPass, isTrue);
        expect(report.monoToStereoUpmix, isTrue);
        expect(report.monoToStereoUpmixPass, isTrue);
        expect(report.stereoToMonoDownmix, isTrue);
        expect(report.stereoToMonoDownmixPass, isTrue);
        expect(report.positiveSaturation, isTrue);
        expect(report.positiveSaturationPass, isTrue);
        expect(report.negativeSaturation, isTrue);
        expect(report.negativeSaturationPass, isTrue);
        expect(report.oddSampleTruncation, isTrue);
        expect(report.oddSampleTruncationPass, isTrue);
        expect(report.negativeDownmixDivision, isTrue);
        expect(report.negativeDownmixDivisionPass, isTrue);
        expect(report.shorterTrackSilence, isTrue);
        expect(report.shorterTrackSilencePass, isTrue);
        expect(report.longerTrackShortWindowMix, isTrue);
        expect(report.longerTrackShortWindowMixPass, isTrue);
        expect(report.fourTrackDeterministicMix, isTrue);
        expect(report.fourTrackDeterministicMixPass, isTrue);
        expect(report.noPrematureClip, isTrue);
        expect(report.noPrematureClipPass, isTrue);
        expect(report.finalSaturation, isTrue);
        expect(report.finalSaturationPass, isTrue);
        expect(report.eightTrackCapacity, isTrue);
        expect(report.eightTrackCapacityPass, isTrue);

        // Rejection lanes
        expect(report.invalidGainRejection, isTrue);
        expect(report.invalidGainRejectionPass, isTrue);
        expect(report.nonFiniteGainRejection, isTrue);
        expect(report.nonFiniteGainRejectionPass, isTrue);
        expect(report.sampleRateMismatchRejection, isTrue);
        expect(report.sampleRateMismatchRejectionPass, isTrue);
        expect(report.invalidTrackChannelCountRejection, isTrue);
        expect(report.invalidTrackChannelCountRejectionPass, isTrue);
        expect(report.insufficientOutputCapacityRejection, isTrue);
        expect(report.insufficientOutputCapacityRejectionPass, isTrue);
        expect(report.invalidSessionRejection, isTrue);
        expect(report.invalidSessionRejectionPass, isTrue);
        expect(report.nineTrackReject, isTrue);
        expect(report.nineTrackRejectPass, isTrue);

        // Lifecycle & topology lanes
        expect(report.topologyPorts, isTrue);
        expect(report.topologyPortsPass, isTrue);
        expect(report.destroyIdempotent, isTrue);
        expect(report.destroyIdempotentPass, isTrue);

        // Aggregate
        expect(report.allNativeLanesPass, isTrue);

        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(serialized['lastError'], equals('none'));
        expect(serialized['raw'], equals(report.raw));
        expect(serialized['metrics'], equals(report.metrics));

        final roundTrip = VGAudioMixBusSmokeReport.fromMap(serialized);
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAudioMixBusSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'metrics': const <String, Object?>{
            'topologyPorts.pass': true,
            'stereoStereoDeterministic.pass': false,
            'monoToStereoUpmix.pass': true,
            'stereoToMonoDownmix.pass': true,
            'positiveSaturation.pass': true,
            'negativeSaturation.pass': true,
            'oddSampleTruncation.pass': true,
            'negativeDownmixDivision.pass': true,
            'shorterTrackSilence.pass': true,
            'longerTrackShortWindowMix.pass': true,
            'fourTrackDeterministicMix.pass': true,
            'noPrematureClip.pass': true,
            'finalSaturation.pass': true,
            'eightTrackCapacity.pass': true,
            'invalidGainRejection.pass': true,
            'nonFiniteGainRejection.pass': true,
            'sampleRateMismatchRejection.pass': true,
            'invalidTrackChannelCountRejection.pass': true,
            'insufficientOutputCapacityRejection.pass': true,
            'invalidSessionRejection.pass': true,
            'nineTrackReject.pass': true,
            'destroyIdempotent.pass': true,
            'laneCount': 22,
            'lanePassCount': 21,
          },
          'lastError': 'stereoStereoDeterministic: output PCM mismatch',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.stereoStereoDeterministic, isFalse);
      expect(report.monoToStereoUpmix, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lanePassCount, equals(21));
      expect(
        report.lastError,
        equals('stereoStereoDeterministic: output PCM mismatch'),
      );
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a', 'b'],
      ]) {
        final report = VGAudioMixBusSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
        expect(report.proofBoundary, isEmpty);
        expect(
          report.raw,
          equals(const <String, String>{'reason': 'native_result_not_a_map'}),
        );
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.allNativeLanesPass, isFalse);
        expect(report.laneCount, equals(22));
        expect(report.lanePassCount, equals(0));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGAudioMixBusSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;checksum=9999;proofBoundary=$_kCanonicalProofBoundary',
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{
          'topologyPorts.pass': true,
          'stereoStereoDeterministic.pass': true,
          'monoToStereoUpmix.pass': true,
          'stereoToMonoDownmix.pass': true,
          'positiveSaturation.pass': true,
          'negativeSaturation.pass': true,
          'oddSampleTruncation.pass': true,
          'negativeDownmixDivision.pass': true,
          'shorterTrackSilence.pass': true,
          'longerTrackShortWindowMix.pass': true,
          'fourTrackDeterministicMix.pass': true,
          'noPrematureClip.pass': true,
          'finalSaturation.pass': true,
          'eightTrackCapacity.pass': true,
          'invalidGainRejection.pass': true,
          'nonFiniteGainRejection.pass': true,
          'sampleRateMismatchRejection.pass': true,
          'invalidTrackChannelCountRejection.pass': true,
          'insufficientOutputCapacityRejection.pass': true,
          'invalidSessionRejection.pass': true,
          'nineTrackReject.pass': true,
          'destroyIdempotent.pass': true,
        },
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.raw['status'], equals('PASS'));
      expect(reportFromRaw.raw['checksum'], equals('9999'));
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in metrics', () {
      final report = VGAudioMixBusSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{
          'topologyPorts.pass': 'true',
          'stereoStereoDeterministic.pass': 'PASS',
          'monoToStereoUpmix.pass': 'success',
          'stereoToMonoDownmix.pass': 'false',
        },
      });

      expect(report.topologyPorts, isTrue);
      expect(report.stereoStereoDeterministic, isTrue);
      expect(report.monoToStereoUpmix, isTrue);
      expect(report.stereoToMonoDownmix, isFalse);
    });
  });

  group('Proof boundary validation', () {
    test('proof boundary validation strictly checks canonical string', () {
      final reportValid = _createSampleReport();
      expect(reportValid.hasCanonicalProofBoundary, isTrue);

      final reportInvalid = _createSampleReport({
        'proofBoundary': 'wrong_proof_boundary_string',
      });
      expect(reportInvalid.hasCanonicalProofBoundary, isFalse);

      final reportEmpty = _createSampleReport({'proofBoundary': ''});
      expect(reportEmpty.hasCanonicalProofBoundary, isFalse);
    });
  });

  group('Individual lane failures and allNativeLanesPass coverage', () {
    test(
      'every single lane failing falsifies allNativeLanesPass and specific getter',
      () {
        final base = _createSampleRawMap();
        final baseMetrics = Map<String, Object?>.from(base['metrics'] as Map);

        expect(_kAllLanes.length, equals(22));

        for (final lane in _kAllLanes) {
          final modifiedMetrics = Map<String, Object?>.from(baseMetrics);
          modifiedMetrics['$lane.pass'] = false;
          modifiedMetrics.remove('lanePassCount'); // Let compute fallback run

          final report = VGAudioMixBusSmokeReport.fromMap({
            ...base,
            'metrics': modifiedMetrics,
          });

          expect(
            report.allNativeLanesPass,
            isFalse,
            reason:
                'Failing lane $lane must cause allNativeLanesPass to be false',
          );

          expect(
            report.lanePassCount,
            equals(21),
            reason: 'Failing lane $lane must decrement lanePassCount to 21',
          );

          // Verify specific getter reflects failure
          switch (lane) {
            case 'topologyPorts':
              expect(report.topologyPorts, isFalse);
              expect(report.topologyPortsPass, isFalse);
              break;
            case 'stereoStereoDeterministic':
              expect(report.stereoStereoDeterministic, isFalse);
              expect(report.stereoStereoDeterministicPass, isFalse);
              break;
            case 'monoToStereoUpmix':
              expect(report.monoToStereoUpmix, isFalse);
              expect(report.monoToStereoUpmixPass, isFalse);
              break;
            case 'stereoToMonoDownmix':
              expect(report.stereoToMonoDownmix, isFalse);
              expect(report.stereoToMonoDownmixPass, isFalse);
              break;
            case 'positiveSaturation':
              expect(report.positiveSaturation, isFalse);
              expect(report.positiveSaturationPass, isFalse);
              break;
            case 'negativeSaturation':
              expect(report.negativeSaturation, isFalse);
              expect(report.negativeSaturationPass, isFalse);
              break;
            case 'oddSampleTruncation':
              expect(report.oddSampleTruncation, isFalse);
              expect(report.oddSampleTruncationPass, isFalse);
              break;
            case 'negativeDownmixDivision':
              expect(report.negativeDownmixDivision, isFalse);
              expect(report.negativeDownmixDivisionPass, isFalse);
              break;
            case 'shorterTrackSilence':
              expect(report.shorterTrackSilence, isFalse);
              expect(report.shorterTrackSilencePass, isFalse);
              break;
            case 'longerTrackShortWindowMix':
              expect(report.longerTrackShortWindowMix, isFalse);
              expect(report.longerTrackShortWindowMixPass, isFalse);
              break;
            case 'fourTrackDeterministicMix':
              expect(report.fourTrackDeterministicMix, isFalse);
              expect(report.fourTrackDeterministicMixPass, isFalse);
              break;
            case 'noPrematureClip':
              expect(report.noPrematureClip, isFalse);
              expect(report.noPrematureClipPass, isFalse);
              break;
            case 'finalSaturation':
              expect(report.finalSaturation, isFalse);
              expect(report.finalSaturationPass, isFalse);
              break;
            case 'eightTrackCapacity':
              expect(report.eightTrackCapacity, isFalse);
              expect(report.eightTrackCapacityPass, isFalse);
              break;
            case 'invalidGainRejection':
              expect(report.invalidGainRejection, isFalse);
              expect(report.invalidGainRejectionPass, isFalse);
              break;
            case 'nonFiniteGainRejection':
              expect(report.nonFiniteGainRejection, isFalse);
              expect(report.nonFiniteGainRejectionPass, isFalse);
              break;
            case 'sampleRateMismatchRejection':
              expect(report.sampleRateMismatchRejection, isFalse);
              expect(report.sampleRateMismatchRejectionPass, isFalse);
              break;
            case 'invalidTrackChannelCountRejection':
              expect(report.invalidTrackChannelCountRejection, isFalse);
              expect(report.invalidTrackChannelCountRejectionPass, isFalse);
              break;
            case 'insufficientOutputCapacityRejection':
              expect(report.insufficientOutputCapacityRejection, isFalse);
              expect(report.insufficientOutputCapacityRejectionPass, isFalse);
              break;
            case 'invalidSessionRejection':
              expect(report.invalidSessionRejection, isFalse);
              expect(report.invalidSessionRejectionPass, isFalse);
              break;
            case 'nineTrackReject':
              expect(report.nineTrackReject, isFalse);
              expect(report.nineTrackRejectPass, isFalse);
              break;
            case 'destroyIdempotent':
              expect(report.destroyIdempotent, isFalse);
              expect(report.destroyIdempotentPass, isFalse);
              break;
            default:
              fail('Unknown lane: $lane');
          }
        }
      },
    );

    test('multiple failed lanes decrease lanePassCount accordingly', () {
      final base = _createSampleRawMap();
      final modifiedMetrics = Map<String, Object?>.from(base['metrics'] as Map);
      modifiedMetrics['topologyPorts.pass'] = false;
      modifiedMetrics['stereoStereoDeterministic.pass'] = false;
      modifiedMetrics['positiveSaturation.pass'] = false;
      modifiedMetrics.remove('lanePassCount');

      final report = VGAudioMixBusSmokeReport.fromMap({
        ...base,
        'metrics': modifiedMetrics,
      });

      expect(report.allNativeLanesPass, isFalse);
      expect(report.lanePassCount, equals(19));
      expect(report.topologyPorts, isFalse);
      expect(report.stereoStereoDeterministic, isFalse);
      expect(report.positiveSaturation, isFalse);
      expect(report.monoToStereoUpmix, isTrue);
    });
  });

  group('Value semantics: equality, hashCode, toString', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGAudioMixBusSmokeReport('));
      expect(a.toString(), contains('pass: true'));
      expect(
        a.toString(),
        contains('proofBoundary: $_kCanonicalProofBoundary'),
      );
    });

    test('inequality when any single field differs', () {
      final base = _createSampleReport();
      final diffs = <Map<String, Object?>>[
        {'pass': false},
        {'proofBoundary': 'other_boundary'},
        {'lastError': 'some_error'},
        {
          'raw': const <String, String>{'custom': 'diff'},
        },
        {
          'metrics': const <String, Object?>{'topologyPorts.pass': false},
        },
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group('MethodChannel wrapper: runAndroidDagPhase4AudioMixBusSmoke', () {
    test(
      'invokes runAndroidDagPhase4AudioMixBusSmoke on default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGAudioMixBusSmokeReport.runAndroidDagPhase4AudioMixBusSmoke();

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4AudioMixBusSmoke'),
        );
        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('invokes on custom injected channel', () async {
      MethodCall? capturedCall;
      const customChannel = MethodChannel('custom_audio_mix_bus_channel');
      binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGAudioMixBusSmokeReport.runAndroidDagPhase4AudioMixBusSmoke(
            channel: customChannel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('runAndroidDagPhase4AudioMixBusSmoke'),
      );
      expect(report.pass, isTrue);
    });

    test('handles PlatformException by returning fallback report', () async {
      const errorChannel = MethodChannel('error_audio_mix_bus_channel');
      binaryMessenger.setMockMethodCallHandler(errorChannel, (call) async {
        throw PlatformException(
          code: 'NATIVE_ERROR',
          message: 'AudioMixBus initialization failed',
        );
      });

      final report =
          await VGAudioMixBusSmokeReport.runAndroidDagPhase4AudioMixBusSmoke(
            channel: errorChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(
        report.lastError,
        contains(
          'platform_exception:NATIVE_ERROR:AudioMixBus initialization failed',
        ),
      );
    });

    test('handles TimeoutException by returning fallback report', () async {
      const slowChannel = MethodChannel('slow_audio_mix_bus_channel');
      binaryMessenger.setMockMethodCallHandler(slowChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });

      final report =
          await VGAudioMixBusSmokeReport.runAndroidDagPhase4AudioMixBusSmoke(
            timeout: const Duration(milliseconds: 20),
            channel: slowChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('timeout'));
    });

    test('handles generic Exception by returning fallback report', () async {
      const exChannel = MethodChannel('ex_audio_mix_bus_channel');
      binaryMessenger.setMockMethodCallHandler(exChannel, (call) async {
        throw Exception('Native crash simulated');
      });

      final report =
          await VGAudioMixBusSmokeReport.runAndroidDagPhase4AudioMixBusSmoke(
            channel: exChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('Native crash simulated'));
    });
  });
}
