// vg_audio_transport_coordinator_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice D: Android True-DAG Phase 4
// native ClockedAudioTransportCoordinator Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_clock_driven_audio_transport_coordinator_proof_only_no_audio_track_no_os_callback_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product_no_internal_wall_clock_read_no_threads_no_locks_no_float_timebase_no_resample_no_speed_change_no_source_provider_ring_seek_output_ring_only_unity_speed_only';

const _kAllLanes = <String>[
  'coordinatorConstructorValidationOk',
  'startAwaitAckGateOk',
  'clockDrivenDispatchOk',
  'boundedCatchUpOk',
  'backpressureNoClockMutationOk',
  'pauseResumeNoDispatchOk',
  'seekAwaitAckGateOk',
  'silenceWindowPushedOk',
  'schedulerErrorNoCursorAdvanceOk',
  'nonUnitySpeedRejectOk',
  'frameConversionOverflowOk',
  'noSteadyStateAllocationOk',
  'lifecycleOk',
  'stackScoped',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final metrics = <String, Object?>{
    'coordinatorConstructorValidationOk': true,
    'startAwaitAckGateOk': true,
    'clockDrivenDispatchOk': true,
    'boundedCatchUpOk': true,
    'backpressureNoClockMutationOk': true,
    'pauseResumeNoDispatchOk': true,
    'seekAwaitAckGateOk': true,
    'silenceWindowPushedOk': true,
    'schedulerErrorNoCursorAdvanceOk': true,
    'nonUnitySpeedRejectOk': true,
    'frameConversionOverflowOk': true,
    'noSteadyStateAllocationOk': true,
    'lifecycleOk': true,
    'stackScoped': true,
    'clockDrivenFramesRendered': 2400,
    'boundedCatchUpCalls': 2,
    'boundedCatchUpTotalFrames': 960,
    'silenceFramesPushed': 480,
    'frameOfPositionSaturated': 0,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'proofBoundary': _kCanonicalProofBoundary,
    'coordinatorConstructorValidationOk': 'true',
    'startAwaitAckGateOk': 'true',
    'clockDrivenDispatchOk': 'true',
    'boundedCatchUpOk': 'true',
    'backpressureNoClockMutationOk': 'true',
    'pauseResumeNoDispatchOk': 'true',
    'seekAwaitAckGateOk': 'true',
    'silenceWindowPushedOk': 'true',
    'schedulerErrorNoCursorAdvanceOk': 'true',
    'nonUnitySpeedRejectOk': 'true',
    'frameConversionOverflowOk': 'true',
    'noSteadyStateAllocationOk': 'true',
    'lifecycleOk': 'true',
    'stackScoped': 'true',
    'clockDrivenFramesRendered': '2400',
    'boundedCatchUpCalls': '2',
    'boundedCatchUpTotalFrames': '960',
    'silenceFramesPushed': '480',
    'frameOfPositionSaturated': '0',
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

VGAudioTransportCoordinatorSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGAudioTransportCoordinatorSmokeReport.fromMap(
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

  group('VGAudioTransportCoordinatorSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGAudioTransportCoordinatorSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.lastError, isEmpty);

        // Boolean lane getters
        expect(report.coordinatorConstructorValidationOk, isTrue);
        expect(report.startAwaitAckGateOk, isTrue);
        expect(report.clockDrivenDispatchOk, isTrue);
        expect(report.boundedCatchUpOk, isTrue);
        expect(report.backpressureNoClockMutationOk, isTrue);
        expect(report.pauseResumeNoDispatchOk, isTrue);
        expect(report.seekAwaitAckGateOk, isTrue);
        expect(report.silenceWindowPushedOk, isTrue);
        expect(report.schedulerErrorNoCursorAdvanceOk, isTrue);
        expect(report.nonUnitySpeedRejectOk, isTrue);
        expect(report.frameConversionOverflowOk, isTrue);
        expect(report.noSteadyStateAllocationOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.stackScoped, isTrue);

        // Numeric getters
        expect(report.clockDrivenFramesRendered, equals(2400));
        expect(report.boundedCatchUpCalls, equals(2));
        expect(report.boundedCatchUpTotalFrames, equals(960));
        expect(report.silenceFramesPushed, equals(480));
        expect(report.frameOfPositionSaturated, equals(0));

        // Aggregate
        expect(report.allNativeLanesPass, isTrue);

        // Serialization
        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(serialized['lastError'], equals(''));
        expect(serialized['raw'], equals(report.raw));
        expect(serialized['metrics'], equals(report.metrics));

        final roundTrip = VGAudioTransportCoordinatorSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAudioTransportCoordinatorSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'metrics': const <String, Object?>{
            'coordinatorConstructorValidationOk': true,
            'startAwaitAckGateOk': false,
            'clockDrivenDispatchOk': true,
            'boundedCatchUpOk': true,
            'backpressureNoClockMutationOk': true,
            'pauseResumeNoDispatchOk': true,
            'seekAwaitAckGateOk': true,
            'silenceWindowPushedOk': true,
            'schedulerErrorNoCursorAdvanceOk': true,
            'nonUnitySpeedRejectOk': true,
            'frameConversionOverflowOk': true,
            'noSteadyStateAllocationOk': true,
            'lifecycleOk': true,
            'stackScoped': true,
          },
          'lastError': 'start_ack_gate_failed',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.startAwaitAckGateOk, isFalse);
      expect(report.coordinatorConstructorValidationOk, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, equals('start_ack_gate_failed'));
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a', 'b'],
      ]) {
        final report = VGAudioTransportCoordinatorSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
        expect(report.proofBoundary, isEmpty);
        expect(
          report.raw,
          equals(const <String, String>{'reason': 'native_result_not_a_map'}),
        );
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.allNativeLanesPass, isFalse);
        expect(report.clockDrivenFramesRendered, equals(0));
        expect(report.boundedCatchUpCalls, equals(0));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGAudioTransportCoordinatorSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'coordinatorConstructorValidationOk=true;'
            'startAwaitAckGateOk=true;'
            'clockDrivenDispatchOk=true;'
            'boundedCatchUpOk=true;'
            'backpressureNoClockMutationOk=true;'
            'pauseResumeNoDispatchOk=true;'
            'seekAwaitAckGateOk=true;'
            'silenceWindowPushedOk=true;'
            'schedulerErrorNoCursorAdvanceOk=true;'
            'nonUnitySpeedRejectOk=true;'
            'frameConversionOverflowOk=true;'
            'noSteadyStateAllocationOk=true;'
            'lifecycleOk=true;'
            'stackScoped=true;'
            'clockDrivenFramesRendered=2400;'
            'boundedCatchUpCalls=2;'
            'boundedCatchUpTotalFrames=960;'
            'silenceFramesPushed=480;'
            'frameOfPositionSaturated=0',
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.raw['status'], equals('PASS'));
      expect(reportFromRaw.raw['clockDrivenFramesRendered'], equals('2400'));
      expect(reportFromRaw.clockDrivenFramesRendered, equals(2400));
      expect(reportFromRaw.boundedCatchUpCalls, equals(2));
      expect(reportFromRaw.boundedCatchUpTotalFrames, equals(960));
      expect(reportFromRaw.silenceFramesPushed, equals(480));
      expect(reportFromRaw.frameOfPositionSaturated, equals(0));
      expect(reportFromRaw.coordinatorConstructorValidationOk, isTrue);
      expect(reportFromRaw.startAwaitAckGateOk, isTrue);
      expect(reportFromRaw.clockDrivenDispatchOk, isTrue);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in metrics', () {
      final report = VGAudioTransportCoordinatorSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{
          'coordinatorConstructorValidationOk': 'true',
          'startAwaitAckGateOk': 'PASS',
          'clockDrivenDispatchOk': 'success',
          'boundedCatchUpOk': 'false',
        },
      });

      expect(report.coordinatorConstructorValidationOk, isTrue);
      expect(report.startAwaitAckGateOk, isTrue);
      expect(report.clockDrivenDispatchOk, isTrue);
      expect(report.boundedCatchUpOk, isFalse);
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

          final report = VGAudioTransportCoordinatorSmokeReport.fromMap({
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
            case 'coordinatorConstructorValidationOk':
              expect(report.coordinatorConstructorValidationOk, isFalse);
              break;
            case 'startAwaitAckGateOk':
              expect(report.startAwaitAckGateOk, isFalse);
              break;
            case 'clockDrivenDispatchOk':
              expect(report.clockDrivenDispatchOk, isFalse);
              break;
            case 'boundedCatchUpOk':
              expect(report.boundedCatchUpOk, isFalse);
              break;
            case 'backpressureNoClockMutationOk':
              expect(report.backpressureNoClockMutationOk, isFalse);
              break;
            case 'pauseResumeNoDispatchOk':
              expect(report.pauseResumeNoDispatchOk, isFalse);
              break;
            case 'seekAwaitAckGateOk':
              expect(report.seekAwaitAckGateOk, isFalse);
              break;
            case 'silenceWindowPushedOk':
              expect(report.silenceWindowPushedOk, isFalse);
              break;
            case 'schedulerErrorNoCursorAdvanceOk':
              expect(report.schedulerErrorNoCursorAdvanceOk, isFalse);
              break;
            case 'nonUnitySpeedRejectOk':
              expect(report.nonUnitySpeedRejectOk, isFalse);
              break;
            case 'frameConversionOverflowOk':
              expect(report.frameConversionOverflowOk, isFalse);
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
      expect(a.toString(), contains('VGAudioTransportCoordinatorSmokeReport('));
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
          'metrics': const <String, Object?>{
            'coordinatorConstructorValidationOk': false,
          },
        },
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group('MethodChannel wrapper: runAndroidDagPhase4AudioTransportCoordinatorSmoke', () {
    test(
      'invokes runAndroidDagPhase4AudioTransportCoordinatorSmoke on default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGAudioTransportCoordinatorSmokeReport.runAndroidDagPhase4AudioTransportCoordinatorSmoke();

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4AudioTransportCoordinatorSmoke'),
        );
        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('invokes on custom injected channel', () async {
      MethodCall? capturedCall;
      const customChannel = MethodChannel(
        'custom_audio_transport_coordinator_channel',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGAudioTransportCoordinatorSmokeReport.runAndroidDagPhase4AudioTransportCoordinatorSmoke(
            channel: customChannel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('runAndroidDagPhase4AudioTransportCoordinatorSmoke'),
      );
      expect(report.pass, isTrue);
    });

    test('handles PlatformException by returning fallback report', () async {
      const errorChannel = MethodChannel(
        'error_audio_transport_coordinator_channel',
      );
      binaryMessenger.setMockMethodCallHandler(errorChannel, (call) async {
        throw PlatformException(
          code: 'NATIVE_ERROR',
          message: 'AudioTransportCoordinator initialization failed',
        );
      });

      final report =
          await VGAudioTransportCoordinatorSmokeReport.runAndroidDagPhase4AudioTransportCoordinatorSmoke(
            channel: errorChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(
        report.lastError,
        contains(
          'platform_exception:NATIVE_ERROR:AudioTransportCoordinator initialization failed',
        ),
      );
    });

    test('handles TimeoutException by returning fallback report', () async {
      const slowChannel = MethodChannel(
        'slow_audio_transport_coordinator_channel',
      );
      binaryMessenger.setMockMethodCallHandler(slowChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });

      final report =
          await VGAudioTransportCoordinatorSmokeReport.runAndroidDagPhase4AudioTransportCoordinatorSmoke(
            timeout: const Duration(milliseconds: 20),
            channel: slowChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('timeout'));
    });

    test('handles generic Exception by returning fallback report', () async {
      const exChannel = MethodChannel('ex_audio_transport_coordinator_channel');
      binaryMessenger.setMockMethodCallHandler(exChannel, (call) async {
        throw Exception('Native crash simulated');
      });

      final report =
          await VGAudioTransportCoordinatorSmokeReport.runAndroidDagPhase4AudioTransportCoordinatorSmoke(
            channel: exChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('Native crash simulated'));
    });
  });
}
