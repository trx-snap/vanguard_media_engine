// vg_async_runtime_queue_scheduler_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-RUNTIME-QUEUE-SCHEDULER: Android True-DAG
// Phase 4 async runtime queue/backpressure scheduler integration Dart model
// and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'diagnostic_async_runtime_queue_scheduler_integration_proof_only_worker_owned_clock_and_coordinator_command_serialized_source_ring_spsc_output_ring_spsc_caller_derived_systime_ticks_only_steady_clock_pacing_only_no_native_media_timebase_no_audible_output_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_product_editor_app_wiring_no_streaming_cache_no_ios_no_export_route_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_SCHEDULER_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_SCHEDULER_SMOKE_FAIL';
const _kChecksumHex = '00000000abcdef12';

const _kLaneKeys = <String>[
  'asyncThreadDecouplingOk',
  'controlCommandSerializationOk',
  'sourceBackpressureOk',
  'outputBackpressureOk',
  'providerZeroFillAccountingOk',
  'seekEpochCoordinationOk',
  'checksumAccountingOk',
  'workerJoinOnDestroyOk',
  'idempotentDestroyOk',
  'noOwnerThreadDispatchOk',
  'proofBoundaryOk',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    for (final lane in _kLaneKeys) lane: true,
  };

  final metrics = <String, Object?>{
    'workerThreadDistinct': true,
    'ownerDispatchCalls': 0,
    'commandsEnqueued': 4,
    'commandsProcessed': 4,
    'commandErrors': 0,
    'dispatchCount': 66,
    'okCount': 64,
    'silenceCount': 0,
    'backpressureCount': 2,
    'schedulerErrorCount': 0,
    'writerBackpressureRejects': 1,
    'providerUnderrunEvents': 0,
    'providerFramesZeroFilled': 0,
    'providerForwardSkipFrames': 0,
    'providerRewindRejects': 0,
    'totalFramesAccepted': 16384,
    'totalFramesRendered': 16384,
    'totalFramesPushed': 16384,
    'totalOutputFramesRead': 16384,
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeOutputReadChecksumHex': _kChecksumHex,
    'probeZeroFillWindows': 2,
    'probeFramesZeroFilled': 384,
    'probeUnderrunEvents': 2,
    'probeSilenceCount': 1,
    'probeFramesPushed': 1024,
    'probeFramesRead': 1024,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'mainWindows=64|expectedFrames=16384|probeExpected=1024',
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

class _ThrowingMethodChannel extends MethodChannel {
  const _ThrowingMethodChannel(super.name);

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) {
    throw const FormatException('simulated non-platform exception');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGAsyncRuntimeQueueSchedulerSmokeReport fromMap and toMap', () {
    test('pass report parses all lanes, metrics, and fields cleanly', () {
      final report = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.marker, equals(_kPassMarker));
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.failureReason, isEmpty);
      expect(report.lastError, isEmpty);
      expect(report.details, contains('expectedFrames=16384'));

      // Lanes (11 lanes)
      expect(report.asyncThreadDecouplingOk, isTrue);
      expect(report.controlCommandSerializationOk, isTrue);
      expect(report.sourceBackpressureOk, isTrue);
      expect(report.outputBackpressureOk, isTrue);
      expect(report.providerZeroFillAccountingOk, isTrue);
      expect(report.seekEpochCoordinationOk, isTrue);
      expect(report.checksumAccountingOk, isTrue);
      expect(report.workerJoinOnDestroyOk, isTrue);
      expect(report.idempotentDestroyOk, isTrue);
      expect(report.noOwnerThreadDispatchOk, isTrue);
      expect(report.proofBoundaryOk, isTrue);

      // Metrics
      expect(report.workerThreadDistinct, isTrue);
      expect(report.ownerDispatchCalls, equals(0));
      expect(report.commandsEnqueued, equals(4));
      expect(report.commandsProcessed, equals(4));
      expect(report.commandErrors, equals(0));
      expect(report.dispatchCount, equals(66));
      expect(report.silenceCount, equals(0));
      expect(report.backpressureCount, equals(2));
      expect(report.writerBackpressureRejects, equals(1));
      expect(report.providerFramesZeroFilled, equals(0));
      expect(report.totalFramesAccepted, equals(16384));
      expect(report.totalFramesRendered, equals(16384));
      expect(report.totalFramesPushed, equals(16384));
      expect(report.totalOutputFramesRead, equals(16384));
      expect(report.kotlinAcceptedChecksumHex, equals(_kChecksumHex));
      expect(report.nativeAcceptedChecksumHex, equals(_kChecksumHex));
      expect(report.nativeOutputReadChecksumHex, equals(_kChecksumHex));
      expect(report.probeFramesZeroFilled, equals(384));
      expect(report.probeSilenceCount, equals(1));

      // Getters
      expect(report.checksumsMatch, isTrue);
      expect(report.allNativeLanesPass, isTrue);

      // Serialization round-trip.
      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['marker'], equals(_kPassMarker));
      expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
      final roundTrip = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        serialized,
      );
      expect(roundTrip, equals(report));
    });

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'status': 'checksum_accounting_mismatch',
          'marker': _kFailMarker,
          'failureReason': 'checksum_accounting_mismatch',
          'lastError': 'checksum_accounting_mismatch',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.status, equals('checksum_accounting_mismatch'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('checksum_accounting_mismatch'));
      expect(report.lastError, equals('checksum_accounting_mismatch'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [null, 'not_a_map', 12345, 3.14, <Object?>['a']]) {
        final report = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
        expect(report.proofBoundary, isEmpty);
        expect(report.status, equals('fail'));
        expect(report.marker, equals(_kFailMarker));
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.allNativeLanesPass, isFalse);
        expect(report.totalFramesAccepted, equals(0));
        expect(report.ownerDispatchCalls, equals(-1));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final report = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'marker=$_kPassMarker;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'asyncThreadDecouplingOk=true;'
            'controlCommandSerializationOk=true;'
            'sourceBackpressureOk=true;'
            'outputBackpressureOk=true;'
            'providerZeroFillAccountingOk=true;'
            'seekEpochCoordinationOk=true;'
            'checksumAccountingOk=true;'
            'workerJoinOnDestroyOk=true;'
            'idempotentDestroyOk=true;'
            'noOwnerThreadDispatchOk=true;'
            'proofBoundaryOk=true;'
            'workerThreadDistinct=true;'
            'ownerDispatchCalls=0;'
            'commandsEnqueued=4;'
            'commandsProcessed=4;'
            'commandErrors=0;'
            'dispatchCount=66;'
            'silenceCount=0;'
            'backpressureCount=2;'
            'writerBackpressureRejects=1;'
            'providerFramesZeroFilled=0;'
            'totalFramesAccepted=16384;'
            'totalFramesRendered=16384;'
            'totalFramesPushed=16384;'
            'totalOutputFramesRead=16384;'
            'kotlinAcceptedChecksumHex=$_kChecksumHex;'
            'nativeAcceptedChecksumHex=$_kChecksumHex;'
            'nativeOutputReadChecksumHex=$_kChecksumHex;'
            'probeFramesZeroFilled=384;'
            'probeSilenceCount=1',
      });

      expect(report.pass, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.asyncThreadDecouplingOk, isTrue);
      expect(report.workerThreadDistinct, isTrue);
      expect(report.checksumsMatch, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });
  });

  group('allNativeLanesPass verification contract', () {
    test('requires proofBoundary to match canonical constant', () {
      final report = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'proofBoundary': 'shortened_boundary'}),
      );
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires marker to match pass marker constant', () {
      final report = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'marker': _kFailMarker}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires every lane boolean to be true', () {
      for (final lane in _kLaneKeys) {
        final report = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
          _createSampleRawMap({lane: false}),
        );
        expect(
          report.allNativeLanesPass,
          isFalse,
          reason: '$lane=false must cause allNativeLanesPass to be false',
        );
      }
    });

    test('requires distinct worker thread and zero owner dispatch calls', () {
      final notDistinct = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'workerThreadDistinct': false}),
      );
      expect(notDistinct.allNativeLanesPass, isFalse);

      final ownerDispatched = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'ownerDispatchCalls': 1}),
      );
      expect(ownerDispatched.allNativeLanesPass, isFalse);
    });

    test('requires command serialization lockstep with zero errors', () {
      final unbalanced = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'commandsProcessed': 3}),
      );
      expect(unbalanced.allNativeLanesPass, isFalse);

      final errored = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'commandErrors': 1}),
      );
      expect(errored.allNativeLanesPass, isFalse);
    });

    test('requires checksum identity across all three checksums', () {
      final mismatch = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({
          'nativeOutputReadChecksumHex': '0000000022222222',
        }),
      );
      expect(mismatch.checksumsMatch, isFalse);
      expect(mismatch.allNativeLanesPass, isFalse);

      final empty = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'kotlinAcceptedChecksumHex': ''}),
      );
      expect(empty.checksumsMatch, isFalse);
      expect(empty.allNativeLanesPass, isFalse);
    });

    test('requires lockstep frame accounting (accepted through read)', () {
      final report = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'totalOutputFramesRead': 16000}),
      );
      expect(report.allNativeLanesPass, isFalse);

      final zero = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({
          'totalFramesAccepted': 0,
          'totalFramesRendered': 0,
          'totalFramesPushed': 0,
          'totalOutputFramesRead': 0,
        }),
      );
      expect(zero.allNativeLanesPass, isFalse);
    });

    test('requires observed backpressure on both rings', () {
      final noOutputBp = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'backpressureCount': 0}),
      );
      expect(noOutputBp.allNativeLanesPass, isFalse);

      final noSourceBp = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'writerBackpressureRejects': 0}),
      );
      expect(noSourceBp.allNativeLanesPass, isFalse);
    });

    test('requires clean main identity but a non-empty zero-fill probe', () {
      final zeroFilledMain = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'providerFramesZeroFilled': 1}),
      );
      expect(zeroFilledMain.allNativeLanesPass, isFalse);

      final silentMain = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'silenceCount': 1}),
      );
      expect(silentMain.allNativeLanesPass, isFalse);

      final emptyProbe = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'probeFramesZeroFilled': 0}),
      );
      expect(emptyProbe.allNativeLanesPass, isFalse);
    });
  });

  group('MethodChannel invocation wrapper', () {
    test('sends exact default arguments', () async {
      Map<String, Object?>? capturedArgs;
      String? capturedMethod;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedMethod = call.method;
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createSampleRawMap();
      });

      final report =
          await VGAsyncRuntimeQueueSchedulerSmokeReport.runAsyncRuntimeQueueSchedulerSmoke();

      expect(capturedMethod, equals('runAsyncRuntimeQueueSchedulerSmoke'));
      expect(
        capturedArgs,
        equals(<String, Object?>{
          'sampleRate': 48000,
          'channelCount': 2,
          'maxFramesPerMix': 256,
          'sourceRingCapacityFrames': 4096,
          'outputRingCapacityFrames': 1024,
          'mainWindows': 64,
          'deadlineMs': 30000,
        }),
      );
      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('sends custom arguments and maps timeout to deadlineMs', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createSampleRawMap();
      });

      final report =
          await VGAsyncRuntimeQueueSchedulerSmokeReport.runAsyncRuntimeQueueSchedulerSmoke(
            sampleRate: 44100,
            channelCount: 1,
            maxFramesPerMix: 128,
            sourceRingCapacityFrames: 2048,
            outputRingCapacityFrames: 512,
            mainWindows: 32,
            timeout: const Duration(seconds: 15),
          );

      expect(
        capturedArgs,
        equals(<String, Object?>{
          'sampleRate': 44100,
          'channelCount': 1,
          'maxFramesPerMix': 128,
          'sourceRingCapacityFrames': 2048,
          'outputRingCapacityFrames': 512,
          'mainWindows': 32,
          'deadlineMs': 15000,
        }),
      );
      expect(report.pass, isTrue);
    });

    test('PlatformException produces fail-shaped report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw PlatformException(
          code: 'P4_ASYNC_RUNTIME_QUEUE_SCHEDULER_SMOKE_BUSY',
          message: 'runAsyncRuntimeQueueSchedulerSmoke: busy',
        );
      });

      final report =
          await VGAsyncRuntimeQueueSchedulerSmokeReport.runAsyncRuntimeQueueSchedulerSmoke();

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_ASYNC_RUNTIME_QUEUE_SCHEDULER_SMOKE_BUSY',
        ),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('missing plugin produces unsupported fail-shaped report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw MissingPluginException('no implementation');
      });

      final report =
          await VGAsyncRuntimeQueueSchedulerSmokeReport.runAsyncRuntimeQueueSchedulerSmoke();

      expect(report.pass, isFalse);
      expect(report.failureReason, equals('unsupported_platform'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('TimeoutException produces fail-shaped report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return _createSampleRawMap();
      });

      final report =
          await VGAsyncRuntimeQueueSchedulerSmokeReport.runAsyncRuntimeQueueSchedulerSmoke(
            timeout: const Duration(milliseconds: 10),
          );

      expect(report.pass, isFalse);
      expect(report.failureReason, equals('timeout'));
      expect(report.lastError, contains('timeout'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('generic exception produces fail-shaped report', () async {
      final report =
          await VGAsyncRuntimeQueueSchedulerSmokeReport.runAsyncRuntimeQueueSchedulerSmoke(
            channel: const _ThrowingMethodChannel('test_throwing'),
          );

      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('exception:'));
      expect(report.lastError, contains('simulated non-platform exception'));
      expect(report.allNativeLanesPass, isFalse);
    });
  });

  group('Equality, hashCode, and toString', () {
    test('equal reports compare equal and have identical hashCode', () {
      final reportA = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap(),
      );
      final reportB = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(reportA, equals(reportB));
      expect(reportA.hashCode, equals(reportB.hashCode));
      expect(
        reportA.toString(),
        contains('VGAsyncRuntimeQueueSchedulerSmokeReport('),
      );
    });

    test('different reports do not compare equal', () {
      final reportA = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'totalFramesAccepted': 16384}),
      );
      final reportB = VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(
        _createSampleRawMap({'totalFramesAccepted': 20000}),
      );

      expect(reportA, isNot(equals(reportB)));
    });
  });
}
