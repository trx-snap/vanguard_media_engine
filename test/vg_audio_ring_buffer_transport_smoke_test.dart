// vg_audio_ring_buffer_transport_smoke_test.dart
// vanguard_media_engine — P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice B: Android True-DAG Phase 4
// native SPSC audio ring-buffer transport primitive + diagnostic provider adapter Dart model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_spsc_audio_ring_buffer_transport_primitive_and_diagnostic_provider_adapter_only_no_realtime_no_audio_track_no_playback_no_clock_ownership_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product';

const _kAllLanes = <String>[
  'ringSpscLockFreeOk',
  'ringCapacityBoundOk',
  'ringNoAllocationOk',
  'fifoOrderIntegrityOk',
  'wraparoundIntegrityOk',
  'noTornFrameOk',
  'overrunRejectOk',
  'underrunZeroFillOk',
  'underrunSilentWindowOk',
  'rewindRejectOk',
  'forwardSkipBoundedOk',
  'flushDrainSemanticsOk',
  'seekEpochHandshakeOk',
  'concurrentProducerConsumerOk',
  'schedulerIntegrationChecksumOk',
  'teardownWhileQuiescedOk',
  'lifecycleOk',
  'stackScoped',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final metrics = <String, Object?>{
    'ringSpscLockFreeOk': true,
    'ringCapacityBoundOk': true,
    'ringNoAllocationOk': true,
    'fifoOrderIntegrityOk': true,
    'wraparoundIntegrityOk': true,
    'noTornFrameOk': true,
    'overrunRejectOk': true,
    'underrunZeroFillOk': true,
    'underrunSilentWindowOk': true,
    'rewindRejectOk': true,
    'forwardSkipBoundedOk': true,
    'flushDrainSemanticsOk': true,
    'seekEpochHandshakeOk': true,
    'concurrentProducerConsumerOk': true,
    'schedulerIntegrationChecksumOk': true,
    'teardownWhileQuiescedOk': true,
    'lifecycleOk': true,
    'stackScoped': true,
    'framesPushed': 1000000,
    'framesPopped': 1000000,
    'overrunEvents': 1,
    'framesRejected': 8,
    'underrunEvents': 1,
    'framesZeroFilled': 10,
    'forwardSkipFrames': 50,
    'rewindRejects': 1,
    'seekRequest': 1,
    'seekAck': 1,
    'concurrentFrames': 1000000,
    'concurrentRepetitions': 20,
    'producerChecksum': 987654321,
    'consumerChecksum': 987654321,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'proofBoundary': _kCanonicalProofBoundary,
    'ringSpscLockFreeOk': 'true',
    'ringCapacityBoundOk': 'true',
    'ringNoAllocationOk': 'true',
    'fifoOrderIntegrityOk': 'true',
    'wraparoundIntegrityOk': 'true',
    'noTornFrameOk': 'true',
    'overrunRejectOk': 'true',
    'underrunZeroFillOk': 'true',
    'underrunSilentWindowOk': 'true',
    'rewindRejectOk': 'true',
    'forwardSkipBoundedOk': 'true',
    'flushDrainSemanticsOk': 'true',
    'seekEpochHandshakeOk': 'true',
    'concurrentProducerConsumerOk': 'true',
    'schedulerIntegrationChecksumOk': 'true',
    'teardownWhileQuiescedOk': 'true',
    'lifecycleOk': 'true',
    'stackScoped': 'true',
    'framesPushed': '1000000',
    'framesPopped': '1000000',
    'overrunEvents': '1',
    'framesRejected': '8',
    'underrunEvents': '1',
    'framesZeroFilled': '10',
    'forwardSkipFrames': '50',
    'rewindRejects': '1',
    'seekRequest': '1',
    'seekAck': '1',
    'concurrentFrames': '1000000',
    'concurrentRepetitions': '20',
    'producerChecksum': '987654321',
    'consumerChecksum': '987654321',
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

VGAudioRingBufferTransportSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGAudioRingBufferTransportSmokeReport.fromMap(
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

  group('VGAudioRingBufferTransportSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGAudioRingBufferTransportSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.lastError, isEmpty);

        // Boolean lane getters
        expect(report.ringSpscLockFreeOk, isTrue);
        expect(report.ringCapacityBoundOk, isTrue);
        expect(report.ringNoAllocationOk, isTrue);
        expect(report.fifoOrderIntegrityOk, isTrue);
        expect(report.wraparoundIntegrityOk, isTrue);
        expect(report.noTornFrameOk, isTrue);
        expect(report.overrunRejectOk, isTrue);
        expect(report.underrunZeroFillOk, isTrue);
        expect(report.underrunSilentWindowOk, isTrue);
        expect(report.rewindRejectOk, isTrue);
        expect(report.forwardSkipBoundedOk, isTrue);
        expect(report.flushDrainSemanticsOk, isTrue);
        expect(report.seekEpochHandshakeOk, isTrue);
        expect(report.concurrentProducerConsumerOk, isTrue);
        expect(report.schedulerIntegrationChecksumOk, isTrue);
        expect(report.teardownWhileQuiescedOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.stackScoped, isTrue);

        // Numeric getters
        expect(report.framesPushed, equals(1000000));
        expect(report.framesPopped, equals(1000000));
        expect(report.overrunEvents, equals(1));
        expect(report.framesRejected, equals(8));
        expect(report.underrunEvents, equals(1));
        expect(report.framesZeroFilled, equals(10));
        expect(report.forwardSkipFrames, equals(50));
        expect(report.rewindRejects, equals(1));
        expect(report.seekRequest, equals(1));
        expect(report.seekAck, equals(1));
        expect(report.concurrentFrames, equals(1000000));
        expect(report.concurrentRepetitions, equals(20));
        expect(report.producerChecksum, equals(987654321));
        expect(report.consumerChecksum, equals(987654321));

        // Aggregate
        expect(report.allNativeLanesPass, isTrue);

        // Serialization
        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(serialized['lastError'], equals(''));
        expect(serialized['raw'], equals(report.raw));
        expect(serialized['metrics'], equals(report.metrics));

        final roundTrip = VGAudioRingBufferTransportSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAudioRingBufferTransportSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'metrics': const <String, Object?>{
            'ringSpscLockFreeOk': true,
            'ringCapacityBoundOk': false,
            'ringNoAllocationOk': true,
            'fifoOrderIntegrityOk': true,
            'wraparoundIntegrityOk': true,
            'noTornFrameOk': true,
            'overrunRejectOk': true,
            'underrunZeroFillOk': true,
            'underrunSilentWindowOk': true,
            'rewindRejectOk': true,
            'forwardSkipBoundedOk': true,
            'flushDrainSemanticsOk': true,
            'seekEpochHandshakeOk': true,
            'concurrentProducerConsumerOk': true,
            'schedulerIntegrationChecksumOk': true,
            'teardownWhileQuiescedOk': true,
            'lifecycleOk': true,
            'stackScoped': true,
          },
          'lastError': 'ring_capacity_bound_failed',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.ringCapacityBoundOk, isFalse);
      expect(report.ringSpscLockFreeOk, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, equals('ring_capacity_bound_failed'));
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a', 'b'],
      ]) {
        final report = VGAudioRingBufferTransportSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
        expect(report.proofBoundary, isEmpty);
        expect(
          report.raw,
          equals(const <String, String>{'reason': 'native_result_not_a_map'}),
        );
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.allNativeLanesPass, isFalse);
        expect(report.framesPushed, equals(0));
        expect(report.framesPopped, equals(0));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGAudioRingBufferTransportSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'ringSpscLockFreeOk=true;'
            'ringCapacityBoundOk=true;'
            'ringNoAllocationOk=true;'
            'fifoOrderIntegrityOk=true;'
            'wraparoundIntegrityOk=true;'
            'noTornFrameOk=true;'
            'overrunRejectOk=true;'
            'underrunZeroFillOk=true;'
            'underrunSilentWindowOk=true;'
            'rewindRejectOk=true;'
            'forwardSkipBoundedOk=true;'
            'flushDrainSemanticsOk=true;'
            'seekEpochHandshakeOk=true;'
            'concurrentProducerConsumerOk=true;'
            'schedulerIntegrationChecksumOk=true;'
            'teardownWhileQuiescedOk=true;'
            'lifecycleOk=true;'
            'stackScoped=true;'
            'framesPushed=1000000;'
            'framesPopped=1000000;'
            'overrunEvents=1;'
            'framesRejected=8;'
            'underrunEvents=1;'
            'framesZeroFilled=10;'
            'forwardSkipFrames=50;'
            'rewindRejects=1;'
            'seekRequest=1;'
            'seekAck=1;'
            'concurrentFrames=1000000;'
            'concurrentRepetitions=20;'
            'producerChecksum=987654321;'
            'consumerChecksum=987654321',
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.raw['status'], equals('PASS'));
      expect(reportFromRaw.raw['framesPushed'], equals('1000000'));
      expect(reportFromRaw.framesPushed, equals(1000000));
      expect(reportFromRaw.framesPopped, equals(1000000));
      expect(reportFromRaw.overrunEvents, equals(1));
      expect(reportFromRaw.framesRejected, equals(8));
      expect(reportFromRaw.underrunEvents, equals(1));
      expect(reportFromRaw.framesZeroFilled, equals(10));
      expect(reportFromRaw.forwardSkipFrames, equals(50));
      expect(reportFromRaw.rewindRejects, equals(1));
      expect(reportFromRaw.seekRequest, equals(1));
      expect(reportFromRaw.seekAck, equals(1));
      expect(reportFromRaw.concurrentFrames, equals(1000000));
      expect(reportFromRaw.concurrentRepetitions, equals(20));
      expect(reportFromRaw.producerChecksum, equals(987654321));
      expect(reportFromRaw.consumerChecksum, equals(987654321));
      expect(reportFromRaw.ringSpscLockFreeOk, isTrue);
      expect(reportFromRaw.concurrentProducerConsumerOk, isTrue);
      expect(reportFromRaw.schedulerIntegrationChecksumOk, isTrue);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in metrics', () {
      final report = VGAudioRingBufferTransportSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{
          'ringSpscLockFreeOk': 'true',
          'ringCapacityBoundOk': 'PASS',
          'ringNoAllocationOk': 'success',
          'fifoOrderIntegrityOk': 'false',
        },
      });

      expect(report.ringSpscLockFreeOk, isTrue);
      expect(report.ringCapacityBoundOk, isTrue);
      expect(report.ringNoAllocationOk, isTrue);
      expect(report.fifoOrderIntegrityOk, isFalse);
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

          final report = VGAudioRingBufferTransportSmokeReport.fromMap({
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
            case 'ringSpscLockFreeOk':
              expect(report.ringSpscLockFreeOk, isFalse);
              break;
            case 'ringCapacityBoundOk':
              expect(report.ringCapacityBoundOk, isFalse);
              break;
            case 'ringNoAllocationOk':
              expect(report.ringNoAllocationOk, isFalse);
              break;
            case 'fifoOrderIntegrityOk':
              expect(report.fifoOrderIntegrityOk, isFalse);
              break;
            case 'wraparoundIntegrityOk':
              expect(report.wraparoundIntegrityOk, isFalse);
              break;
            case 'noTornFrameOk':
              expect(report.noTornFrameOk, isFalse);
              break;
            case 'overrunRejectOk':
              expect(report.overrunRejectOk, isFalse);
              break;
            case 'underrunZeroFillOk':
              expect(report.underrunZeroFillOk, isFalse);
              break;
            case 'underrunSilentWindowOk':
              expect(report.underrunSilentWindowOk, isFalse);
              break;
            case 'rewindRejectOk':
              expect(report.rewindRejectOk, isFalse);
              break;
            case 'forwardSkipBoundedOk':
              expect(report.forwardSkipBoundedOk, isFalse);
              break;
            case 'flushDrainSemanticsOk':
              expect(report.flushDrainSemanticsOk, isFalse);
              break;
            case 'seekEpochHandshakeOk':
              expect(report.seekEpochHandshakeOk, isFalse);
              break;
            case 'concurrentProducerConsumerOk':
              expect(report.concurrentProducerConsumerOk, isFalse);
              break;
            case 'schedulerIntegrationChecksumOk':
              expect(report.schedulerIntegrationChecksumOk, isFalse);
              break;
            case 'teardownWhileQuiescedOk':
              expect(report.teardownWhileQuiescedOk, isFalse);
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
      expect(a.toString(), contains('VGAudioRingBufferTransportSmokeReport('));
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
          'metrics': const <String, Object?>{'ringSpscLockFreeOk': false},
        },
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group('MethodChannel wrapper: runAndroidDagPhase4AudioRingBufferTransportSmoke', () {
    test(
      'invokes runAndroidDagPhase4AudioRingBufferTransportSmoke on default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGAudioRingBufferTransportSmokeReport.runAndroidDagPhase4AudioRingBufferTransportSmoke();

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4AudioRingBufferTransportSmoke'),
        );
        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('invokes on custom injected channel', () async {
      MethodCall? capturedCall;
      const customChannel = MethodChannel(
        'custom_audio_ring_buffer_transport_channel',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGAudioRingBufferTransportSmokeReport.runAndroidDagPhase4AudioRingBufferTransportSmoke(
            channel: customChannel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('runAndroidDagPhase4AudioRingBufferTransportSmoke'),
      );
      expect(report.pass, isTrue);
    });

    test('handles PlatformException by returning fallback report', () async {
      const errorChannel = MethodChannel(
        'error_audio_ring_buffer_transport_channel',
      );
      binaryMessenger.setMockMethodCallHandler(errorChannel, (call) async {
        throw PlatformException(
          code: 'NATIVE_ERROR',
          message: 'AudioRingBufferTransport initialization failed',
        );
      });

      final report =
          await VGAudioRingBufferTransportSmokeReport.runAndroidDagPhase4AudioRingBufferTransportSmoke(
            channel: errorChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(
        report.lastError,
        contains(
          'platform_exception:NATIVE_ERROR:AudioRingBufferTransport initialization failed',
        ),
      );
    });

    test('handles TimeoutException by returning fallback report', () async {
      const slowChannel = MethodChannel(
        'slow_audio_ring_buffer_transport_channel',
      );
      binaryMessenger.setMockMethodCallHandler(slowChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });

      final report =
          await VGAudioRingBufferTransportSmokeReport.runAndroidDagPhase4AudioRingBufferTransportSmoke(
            timeout: const Duration(milliseconds: 20),
            channel: slowChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('timeout'));
    });

    test('handles generic Exception by returning fallback report', () async {
      const exChannel = MethodChannel('ex_audio_ring_buffer_transport_channel');
      binaryMessenger.setMockMethodCallHandler(exChannel, (call) async {
        throw Exception('Native crash simulated');
      });

      final report =
          await VGAudioRingBufferTransportSmokeReport.runAndroidDagPhase4AudioRingBufferTransportSmoke(
            channel: exChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('Native crash simulated'));
    });
  });
}
