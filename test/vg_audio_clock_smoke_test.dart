// vg_audio_clock_smoke_test.dart
// vanguard_media_engine — P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice C: Android True-DAG Phase 4
// platform-neutral native AudioClock diagnostic Dart model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_audio_clock_monotonic_timebase_and_drift_proof_only_no_audio_track_no_aaudio_no_audible_playback_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product_no_internal_wall_clock_read';

const _kAllLanes = <String>[
  'audioClockLockFreeOk',
  'clockMathOk',
  'rationalExactnessOk',
  'doubleDivergenceOk',
  'playPauseResumeOk',
  'seekOk',
  'speedMathOk',
  'monotonicityFuzzOk',
  'overflowSaturationOk',
  'invalidSpeedRejectOk',
  'driftTelemetryInertOk',
  'ringSeekCoordinationOk',
  'lifecycleOk',
  'stackScoped',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final metrics = <String, Object?>{
    'audioClockLockFreeOk': true,
    'clockMathOk': true,
    'rationalExactnessOk': true,
    'doubleDivergenceOk': true,
    'playPauseResumeOk': true,
    'seekOk': true,
    'speedMathOk': true,
    'monotonicityFuzzOk': true,
    'overflowSaturationOk': true,
    'invalidSpeedRejectOk': true,
    'driftTelemetryInertOk': true,
    'ringSeekCoordinationOk': true,
    'lifecycleOk': true,
    'stackScoped': true,
    'finalPositionUs': 1000000,
    'pausedPositionUs': 500000,
    'resumedPositionUs': 500000,
    'seekPositionUs': 250000,
    'driftDeltaUs': 0,
    'driftSampleCount': 100,
    'fuzzIterations': 1000,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'proofBoundary': _kCanonicalProofBoundary,
    'audioClockLockFreeOk': 'true',
    'clockMathOk': 'true',
    'rationalExactnessOk': 'true',
    'doubleDivergenceOk': 'true',
    'playPauseResumeOk': 'true',
    'seekOk': 'true',
    'speedMathOk': 'true',
    'monotonicityFuzzOk': 'true',
    'overflowSaturationOk': 'true',
    'invalidSpeedRejectOk': 'true',
    'driftTelemetryInertOk': 'true',
    'ringSeekCoordinationOk': 'true',
    'lifecycleOk': 'true',
    'stackScoped': 'true',
    'finalPositionUs': '1000000',
    'pausedPositionUs': '500000',
    'resumedPositionUs': '500000',
    'seekPositionUs': '250000',
    'driftDeltaUs': '0',
    'driftSampleCount': '100',
    'fuzzIterations': '1000',
  };

  return <String, Object?>{
    'pass': true,
    'proofBoundary': _kCanonicalProofBoundary,
    'raw': raw,
    'metrics': metrics,
    'lastError': '',
    if (overrides != null) ...overrides,
  };
}

VGAudioClockSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGAudioClockSmokeReport.fromMap(_createSampleRawMap(overrides));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGAudioClockSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGAudioClockSmokeReport.fromMap(_createSampleRawMap());

        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.lastError, isEmpty);

        // Boolean lane getters
        expect(report.audioClockLockFreeOk, isTrue);
        expect(report.clockMathOk, isTrue);
        expect(report.rationalExactnessOk, isTrue);
        expect(report.doubleDivergenceOk, isTrue);
        expect(report.playPauseResumeOk, isTrue);
        expect(report.seekOk, isTrue);
        expect(report.speedMathOk, isTrue);
        expect(report.monotonicityFuzzOk, isTrue);
        expect(report.overflowSaturationOk, isTrue);
        expect(report.invalidSpeedRejectOk, isTrue);
        expect(report.driftTelemetryInertOk, isTrue);
        expect(report.ringSeekCoordinationOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.stackScoped, isTrue);

        // Numeric getters
        expect(report.finalPositionUs, equals(1000000));
        expect(report.pausedPositionUs, equals(500000));
        expect(report.resumedPositionUs, equals(500000));
        expect(report.seekPositionUs, equals(250000));
        expect(report.driftDeltaUs, equals(0));
        expect(report.driftSampleCount, equals(100));
        expect(report.fuzzIterations, equals(1000));

        // Aggregate
        expect(report.allNativeLanesPass, isTrue);

        // Serialization
        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(serialized['lastError'], equals(''));
        expect(serialized['raw'], equals(report.raw));
        expect(serialized['metrics'], equals(report.metrics));

        final roundTrip = VGAudioClockSmokeReport.fromMap(serialized);
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAudioClockSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'metrics': const <String, Object?>{
            'audioClockLockFreeOk': true,
            'clockMathOk': false,
            'rationalExactnessOk': true,
            'doubleDivergenceOk': true,
            'playPauseResumeOk': true,
            'seekOk': true,
            'speedMathOk': true,
            'monotonicityFuzzOk': true,
            'overflowSaturationOk': true,
            'invalidSpeedRejectOk': true,
            'driftTelemetryInertOk': true,
            'ringSeekCoordinationOk': true,
            'lifecycleOk': true,
            'stackScoped': true,
          },
          'lastError': 'clock_math_failed',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.clockMathOk, isFalse);
      expect(report.audioClockLockFreeOk, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, equals('clock_math_failed'));
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a', 'b'],
      ]) {
        final report = VGAudioClockSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
        expect(report.proofBoundary, isEmpty);
        expect(
          report.raw,
          equals(const <String, String>{'reason': 'native_result_not_a_map'}),
        );
        expect(
          report.metrics,
          equals(const <String, Object?>{
            'status': 'FAIL',
            'reason': 'native_result_not_a_map',
          }),
        );
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.allNativeLanesPass, isFalse);
      }
    });

    test('fromMap parses raw string fallback key-value pairs', () {
      final rawString =
          'status=PASS;'
          'proofBoundary=$_kCanonicalProofBoundary;'
          'audioClockLockFreeOk=true;'
          'clockMathOk=true;'
          'rationalExactnessOk=true;'
          'doubleDivergenceOk=true;'
          'playPauseResumeOk=true;'
          'seekOk=true;'
          'speedMathOk=true;'
          'monotonicityFuzzOk=true;'
          'overflowSaturationOk=true;'
          'invalidSpeedRejectOk=true;'
          'driftTelemetryInertOk=true;'
          'ringSeekCoordinationOk=true;'
          'lifecycleOk=true;'
          'stackScoped=true;'
          'finalPositionUs=2000000;'
          'driftDeltaUs=50';

      final report = VGAudioClockSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'raw': rawString,
        'metrics': const <String, Object?>{},
      });

      expect(report.pass, isTrue);
      expect(report.audioClockLockFreeOk, isTrue);
      expect(report.clockMathOk, isTrue);
      expect(report.finalPositionUs, equals(2000000));
      expect(report.driftDeltaUs, equals(50));
      expect(report.allNativeLanesPass, isTrue);
    });

    test('boolean parsing handles variations of true and false', () {
      for (final truthy in [
        'true',
        'TRUE',
        'True',
        'pass',
        'PASS',
        'success',
      ]) {
        final report = VGAudioClockSmokeReport.fromMap({
          'pass': true,
          'proofBoundary': _kCanonicalProofBoundary,
          'raw': <String, String>{'audioClockLockFreeOk': truthy},
          'metrics': const <String, Object?>{},
        });
        expect(report.audioClockLockFreeOk, isTrue);
      }

      for (final falsy in ['false', 'FALSE', 'fail', 'unknown', '']) {
        final report = VGAudioClockSmokeReport.fromMap({
          'pass': true,
          'proofBoundary': _kCanonicalProofBoundary,
          'raw': <String, String>{'audioClockLockFreeOk': falsy},
          'metrics': const <String, Object?>{},
        });
        expect(report.audioClockLockFreeOk, isFalse);
      }
    });

    test('numeric getters fall back safely to defaults on invalid strings', () {
      final report = VGAudioClockSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'raw': const <String, String>{
          'finalPositionUs': 'invalid_num',
          'driftDeltaUs': 'not_a_number',
        },
        'metrics': const <String, Object?>{},
      });

      expect(report.finalPositionUs, equals(0));
      expect(report.driftDeltaUs, equals(0));
    });

    test('all 14 boolean lanes are required for allNativeLanesPass', () {
      for (final lane in _kAllLanes) {
        final modifiedMetrics = <String, Object?>{
          for (final l in _kAllLanes) l: true,
          lane: false,
        };
        final report = _createSampleReport({'metrics': modifiedMetrics});
        expect(
          report.allNativeLanesPass,
          isFalse,
          reason: 'Failing $lane should cause allNativeLanesPass to be false',
        );
      }
    });

    test('equality, hashCode, and toString behave correctly', () {
      final a = _createSampleReport();
      final b = _createSampleReport();
      final c = _createSampleReport({'lastError': 'different_error'});

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a.toString(), contains('VGAudioClockSmokeReport'));
      expect(a.toString(), contains('finalPositionUs'));
    });
  });

  group('VGAudioClockSmokeReport MethodChannel invocation', () {
    test(
      'successful invocation dispatches and returns parsed report',
      () async {
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          if (call.method == VGAudioClockSmokeReport.methodName) {
            return _createSampleRawMap();
          }
          return null;
        });

        final report =
            await VGAudioClockSmokeReport.runAndroidDagPhase4AudioClockSmoke();

        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.allNativeLanesPass, isTrue);
        expect(report.finalPositionUs, equals(1000000));
      },
    );

    test('custom injected MethodChannel is respected', () async {
      const customChannel = MethodChannel('custom_channel');
      binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
        if (call.method == VGAudioClockSmokeReport.methodName) {
          return _createSampleRawMap({'lastError': 'custom_channel_ok'});
        }
        return null;
      });

      final report =
          await VGAudioClockSmokeReport.runAndroidDagPhase4AudioClockSmoke(
            channel: customChannel,
          );

      expect(report.pass, isTrue);
      expect(report.lastError, equals('custom_channel_ok'));
    });

    test('PlatformException returns fallback report with error info', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw PlatformException(
          code: 'UNAVAILABLE',
          message: 'coordinator unavailable',
        );
      });

      final report =
          await VGAudioClockSmokeReport.runAndroidDagPhase4AudioClockSmoke();

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.lastError, contains('platform_exception:UNAVAILABLE'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('timeout returns fallback report with timeout reason', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });

      final report =
          await VGAudioClockSmokeReport.runAndroidDagPhase4AudioClockSmoke(
            timeout: const Duration(milliseconds: 20),
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.lastError, contains('timeout'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('general exception returns fallback report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw StateError('arbitrary_engine_error');
      });

      final report =
          await VGAudioClockSmokeReport.runAndroidDagPhase4AudioClockSmoke();

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.lastError, contains('arbitrary_engine_error'));
      expect(report.allNativeLanesPass, isFalse);
    });
  });
}
