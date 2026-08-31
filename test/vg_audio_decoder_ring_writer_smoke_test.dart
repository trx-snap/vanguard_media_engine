// vg_audio_decoder_ring_writer_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice E: Android True-DAG Phase 4
// native AudioDecoderRingWriter Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_audio_decoder_ring_writer_to_spsc_source_ring_ingest_proof_only_no_mediacodec_no_mediaextractor_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_playback_no_os_callback_no_threads_no_locks_no_file_io_no_export_reroute_no_streaming_no_ios_no_product_no_source_node_wiring_no_scheduler_integration_no_resample_no_audible_output_writer_local_eos_only';

const _kAllLanes = <String>[
  'constructorValidationOk',
  'writeSuccessOk',
  'partialWriteOk',
  'ringFullOk',
  'formatMismatchOk',
  'invalidArgumentOk',
  'eosOk',
  'seekAwaitAckGateOk',
  'sourceRingBoundaryOk',
  'noSteadyStateAllocationOk',
  'lifecycleOk',
  'stackScoped',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final metrics = <String, Object?>{
    'constructorValidationOk': true,
    'writeSuccessOk': true,
    'partialWriteOk': true,
    'ringFullOk': true,
    'formatMismatchOk': true,
    'invalidArgumentOk': true,
    'eosOk': true,
    'seekAwaitAckGateOk': true,
    'sourceRingBoundaryOk': true,
    'noSteadyStateAllocationOk': true,
    'lifecycleOk': true,
    'stackScoped': true,
    'partialWriteFramesAccepted': 128,
    'partialWriteEvents': 1,
    'backpressureRejects': 2,
    'formatMismatches': 1,
    'invalidArgumentRejects': 1,
    'awaitingSeekAckRejects': 1,
    'eosEvents': 1,
    'seekRequests': 1,
    'totalFramesWritten': 2048,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'proofBoundary': _kCanonicalProofBoundary,
    'constructorValidationOk': 'true',
    'writeSuccessOk': 'true',
    'partialWriteOk': 'true',
    'ringFullOk': 'true',
    'formatMismatchOk': 'true',
    'invalidArgumentOk': 'true',
    'eosOk': 'true',
    'seekAwaitAckGateOk': 'true',
    'sourceRingBoundaryOk': 'true',
    'noSteadyStateAllocationOk': 'true',
    'lifecycleOk': 'true',
    'stackScoped': 'true',
    'partialWriteFramesAccepted': '128',
    'partialWriteEvents': '1',
    'backpressureRejects': '2',
    'formatMismatches': '1',
    'invalidArgumentRejects': '1',
    'awaitingSeekAckRejects': '1',
    'eosEvents': '1',
    'seekRequests': '1',
    'totalFramesWritten': '2048',
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

VGAudioDecoderRingWriterSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) =>
    VGAudioDecoderRingWriterSmokeReport.fromMap(_createSampleRawMap(overrides));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGAudioDecoderRingWriterSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGAudioDecoderRingWriterSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.lastError, isEmpty);

        // Boolean lane getters
        expect(report.constructorValidationOk, isTrue);
        expect(report.writeSuccessOk, isTrue);
        expect(report.partialWriteOk, isTrue);
        expect(report.ringFullOk, isTrue);
        expect(report.formatMismatchOk, isTrue);
        expect(report.invalidArgumentOk, isTrue);
        expect(report.eosOk, isTrue);
        expect(report.seekAwaitAckGateOk, isTrue);
        expect(report.sourceRingBoundaryOk, isTrue);
        expect(report.noSteadyStateAllocationOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.stackScoped, isTrue);

        // Numeric getters
        expect(report.partialWriteFramesAccepted, equals(128));
        expect(report.partialWriteEvents, equals(1));
        expect(report.backpressureRejects, equals(2));
        expect(report.formatMismatches, equals(1));
        expect(report.invalidArgumentRejects, equals(1));
        expect(report.awaitingSeekAckRejects, equals(1));
        expect(report.eosEvents, equals(1));
        expect(report.seekRequests, equals(1));
        expect(report.totalFramesWritten, equals(2048));

        // Aggregate
        expect(report.allNativeLanesPass, isTrue);

        // Serialization
        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(serialized['lastError'], equals(''));
        expect(serialized['raw'], equals(report.raw));
        expect(serialized['metrics'], equals(report.metrics));

        final roundTrip = VGAudioDecoderRingWriterSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAudioDecoderRingWriterSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'metrics': const <String, Object?>{
            'constructorValidationOk': true,
            'writeSuccessOk': false,
            'partialWriteOk': true,
            'ringFullOk': true,
            'formatMismatchOk': true,
            'invalidArgumentOk': true,
            'eosOk': true,
            'seekAwaitAckGateOk': true,
            'sourceRingBoundaryOk': true,
            'noSteadyStateAllocationOk': true,
            'lifecycleOk': true,
            'stackScoped': true,
          },
          'lastError': 'write_failed',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.writeSuccessOk, isFalse);
      expect(report.constructorValidationOk, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, equals('write_failed'));
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a', 'b'],
      ]) {
        final report = VGAudioDecoderRingWriterSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
        expect(report.proofBoundary, isEmpty);
        expect(
          report.raw,
          equals(const <String, String>{'reason': 'native_result_not_a_map'}),
        );
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.allNativeLanesPass, isFalse);
        expect(report.partialWriteFramesAccepted, equals(0));
        expect(report.totalFramesWritten, equals(0));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGAudioDecoderRingWriterSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'constructorValidationOk=true;'
            'writeSuccessOk=true;'
            'partialWriteOk=true;'
            'ringFullOk=true;'
            'formatMismatchOk=true;'
            'invalidArgumentOk=true;'
            'eosOk=true;'
            'seekAwaitAckGateOk=true;'
            'sourceRingBoundaryOk=true;'
            'noSteadyStateAllocationOk=true;'
            'lifecycleOk=true;'
            'stackScoped=true;'
            'partialWriteFramesAccepted=128;'
            'partialWriteEvents=1;'
            'backpressureRejects=2;'
            'formatMismatches=1;'
            'invalidArgumentRejects=1;'
            'awaitingSeekAckRejects=1;'
            'eosEvents=1;'
            'seekRequests=1;'
            'totalFramesWritten=2048',
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.raw['status'], equals('PASS'));
      expect(reportFromRaw.raw['totalFramesWritten'], equals('2048'));
      expect(reportFromRaw.partialWriteFramesAccepted, equals(128));
      expect(reportFromRaw.partialWriteEvents, equals(1));
      expect(reportFromRaw.backpressureRejects, equals(2));
      expect(reportFromRaw.formatMismatches, equals(1));
      expect(reportFromRaw.invalidArgumentRejects, equals(1));
      expect(reportFromRaw.awaitingSeekAckRejects, equals(1));
      expect(reportFromRaw.eosEvents, equals(1));
      expect(reportFromRaw.seekRequests, equals(1));
      expect(reportFromRaw.totalFramesWritten, equals(2048));
      expect(reportFromRaw.constructorValidationOk, isTrue);
      expect(reportFromRaw.writeSuccessOk, isTrue);
      expect(reportFromRaw.partialWriteOk, isTrue);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in metrics', () {
      final report = VGAudioDecoderRingWriterSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{
          'constructorValidationOk': 'true',
          'writeSuccessOk': 'PASS',
          'partialWriteOk': 'success',
          'ringFullOk': 'false',
        },
      });

      expect(report.constructorValidationOk, isTrue);
      expect(report.writeSuccessOk, isTrue);
      expect(report.partialWriteOk, isTrue);
      expect(report.ringFullOk, isFalse);
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

        for (final lane in _kAllLanes) {
          final modifiedMetrics = Map<String, Object?>.from(baseMetrics);
          modifiedMetrics[lane] = false;

          final report = VGAudioDecoderRingWriterSmokeReport.fromMap({
            ...base,
            'metrics': modifiedMetrics,
          });

          expect(
            report.allNativeLanesPass,
            isFalse,
            reason:
                'Failing lane $lane must cause allNativeLanesPass to be false',
          );

          switch (lane) {
            case 'constructorValidationOk':
              expect(report.constructorValidationOk, isFalse);
              break;
            case 'writeSuccessOk':
              expect(report.writeSuccessOk, isFalse);
              break;
            case 'partialWriteOk':
              expect(report.partialWriteOk, isFalse);
              break;
            case 'ringFullOk':
              expect(report.ringFullOk, isFalse);
              break;
            case 'formatMismatchOk':
              expect(report.formatMismatchOk, isFalse);
              break;
            case 'invalidArgumentOk':
              expect(report.invalidArgumentOk, isFalse);
              break;
            case 'eosOk':
              expect(report.eosOk, isFalse);
              break;
            case 'seekAwaitAckGateOk':
              expect(report.seekAwaitAckGateOk, isFalse);
              break;
            case 'sourceRingBoundaryOk':
              expect(report.sourceRingBoundaryOk, isFalse);
              break;
            case 'noSteadyStateAllocationOk':
              expect(report.noSteadyStateAllocationOk, isFalse);
              break;
            case 'lifecycleOk':
              expect(report.lifecycleOk, isFalse);
              break;
            case 'stackScoped':
              expect(report.stackScoped, isFalse);
              break;
            default:
              fail('Unknown lane: $lane');
          }
        }
      },
    );
  });

  group('Value semantics: equality, hashCode, toString', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGAudioDecoderRingWriterSmokeReport('));
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
          'metrics': const <String, Object?>{'constructorValidationOk': false},
        },
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group('MethodChannel wrapper: runAndroidDagPhase4AudioDecoderRingWriterSmoke', () {
    test(
      'invokes runAndroidDagPhase4AudioDecoderRingWriterSmoke on default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGAudioDecoderRingWriterSmokeReport.runAndroidDagPhase4AudioDecoderRingWriterSmoke();

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4AudioDecoderRingWriterSmoke'),
        );
        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('invokes on custom injected channel', () async {
      MethodCall? capturedCall;
      const customChannel = MethodChannel(
        'custom_audio_decoder_ring_writer_channel',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGAudioDecoderRingWriterSmokeReport.runAndroidDagPhase4AudioDecoderRingWriterSmoke(
            channel: customChannel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('runAndroidDagPhase4AudioDecoderRingWriterSmoke'),
      );
      expect(report.pass, isTrue);
    });

    test('handles PlatformException by returning fallback report', () async {
      const errorChannel = MethodChannel(
        'error_audio_decoder_ring_writer_channel',
      );
      binaryMessenger.setMockMethodCallHandler(errorChannel, (call) async {
        throw PlatformException(
          code: 'NATIVE_ERROR',
          message: 'AudioDecoderRingWriter initialization failed',
        );
      });

      final report =
          await VGAudioDecoderRingWriterSmokeReport.runAndroidDagPhase4AudioDecoderRingWriterSmoke(
            channel: errorChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(
        report.lastError,
        contains(
          'platform_exception:NATIVE_ERROR:AudioDecoderRingWriter initialization failed',
        ),
      );
    });

    test('handles TimeoutException by returning fallback report', () async {
      const slowChannel = MethodChannel(
        'slow_audio_decoder_ring_writer_channel',
      );
      binaryMessenger.setMockMethodCallHandler(slowChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });

      final report =
          await VGAudioDecoderRingWriterSmokeReport.runAndroidDagPhase4AudioDecoderRingWriterSmoke(
            timeout: const Duration(milliseconds: 20),
            channel: slowChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('timeout'));
    });

    test('handles generic Exception by returning fallback report', () async {
      const exChannel = MethodChannel('ex_audio_decoder_ring_writer_channel');
      binaryMessenger.setMockMethodCallHandler(exChannel, (call) async {
        throw Exception('Native crash simulated');
      });

      final report =
          await VGAudioDecoderRingWriterSmokeReport.runAndroidDagPhase4AudioDecoderRingWriterSmoke(
            channel: exChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('Native crash simulated'));
    });
  });
}
