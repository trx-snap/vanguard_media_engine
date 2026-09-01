// vg_async_runtime_queue_real_decoder_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-ASYNC-RUNTIME-QUEUE-REAL-DECODER: Android
// True-DAG Phase 4 real MediaExtractor/MediaCodec decoder to async runtime
// queue scheduler Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'kotlin_owned_real_decoder_to_async_runtime_queue_scheduler_proof_only_mediaextractor_mediacodec_sync_decode_owner_thread_to_native_async_worker_queue_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_media_time_worker_owned_clock_coordinator_output_ring_source_ring_spsc_caller_derived_accepted_frame_axis_ticks_only_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_audible_output_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_product_editor_app_wiring_no_export_route_changes_no_streaming_cache_no_ios_writer_local_eos_only_zero_fill_not_in_identity';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_SMOKE_FAIL';
const _kChecksumHex = '00000000abcdef12';

const _kLaneKeys = <String>[
  'formatProbeOk',
  'decoderEosReachedOk',
  'asyncWorkerOwnershipOk',
  'controlCommandSerializationOk',
  'realDecoderIngestOk',
  'sourceBackpressureRetryOk',
  'outputBackpressureOk',
  'checksumIdentityOk',
  'frameAccountingOk',
  'seekEpochReanchorOk',
  'noOwnerThreadDispatchOk',
  'foreignThreadRejectedOk',
  'workerJoinOnDestroyOk',
  'idempotentDestroyOk',
  'canonicalProofBoundaryOk',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    for (final lane in _kLaneKeys) lane: true,
  };

  final metrics = <String, Object?>{
    'sampleRate': 44100,
    'channelCount': 2,
    'pcmEncoding': 2,
    'expectedFrames': 23808,
    'preSeekFrames': 10752,
    'postSeekFrames': 13056,
    'seekTargetFrame': 10752,
    'totalFramesExtracted': 40960,
    'totalFramesAccepted': 23808,
    'totalFramesRendered': 23808,
    'totalFramesPushed': 23808,
    'totalOutputFramesRead': 23808,
    'framesTruncatedAtSeekBoundary': 512,
    'framesDiscardedAfterBudget': 16640,
    'decoderBenignFormatChangeCount': 0,
    'commandsEnqueued': 4,
    'commandsProcessed': 4,
    'commandErrors': 0,
    'dispatchCount': 95,
    'silenceCount': 0,
    'backpressureCount': 2,
    'writerBackpressureRejects': 1,
    'providerUnderrunEvents': 0,
    'providerFramesZeroFilled': 0,
    'providerForwardSkipFrames': 0,
    'providerRewindRejects': 0,
    'workerThreadDistinct': true,
    'ownerDispatchCalls': 0,
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeOutputReadChecksumHex': _kChecksumHex,
    'maxFramesPerMix': 256,
    'nativeLastStatus': 'ok',
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
    'details': 'seekAcceptedFrame=10752|expectedFrames=23808',
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

  group('VGAsyncRuntimeQueueRealDecoderSmokeReport fromMap and toMap', () {
    test('pass report parses all lanes, metrics, and fields cleanly', () {
      final report = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.marker, equals(_kPassMarker));
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.failureReason, isEmpty);
      expect(report.lastError, isEmpty);
      expect(report.details, contains('seekAcceptedFrame=10752'));

      // Lanes (15 lanes)
      expect(report.formatProbeOk, isTrue);
      expect(report.decoderEosReachedOk, isTrue);
      expect(report.asyncWorkerOwnershipOk, isTrue);
      expect(report.controlCommandSerializationOk, isTrue);
      expect(report.realDecoderIngestOk, isTrue);
      expect(report.sourceBackpressureRetryOk, isTrue);
      expect(report.outputBackpressureOk, isTrue);
      expect(report.checksumIdentityOk, isTrue);
      expect(report.frameAccountingOk, isTrue);
      expect(report.seekEpochReanchorOk, isTrue);
      expect(report.noOwnerThreadDispatchOk, isTrue);
      expect(report.foreignThreadRejectedOk, isTrue);
      expect(report.workerJoinOnDestroyOk, isTrue);
      expect(report.idempotentDestroyOk, isTrue);
      expect(report.canonicalProofBoundaryOk, isTrue);

      // Metrics
      expect(report.sampleRate, equals(44100));
      expect(report.channelCount, equals(2));
      expect(report.expectedFrames, equals(23808));
      expect(report.preSeekFrames, equals(10752));
      expect(report.postSeekFrames, equals(13056));
      expect(report.seekTargetFrame, equals(10752));
      expect(report.totalFramesExtracted, equals(40960));
      expect(report.totalFramesAccepted, equals(23808));
      expect(report.totalFramesRendered, equals(23808));
      expect(report.totalFramesPushed, equals(23808));
      expect(report.totalOutputFramesRead, equals(23808));
      expect(report.framesTruncatedAtSeekBoundary, equals(512));
      expect(report.framesDiscardedAfterBudget, equals(16640));
      expect(report.commandsEnqueued, equals(4));
      expect(report.commandsProcessed, equals(4));
      expect(report.commandErrors, equals(0));
      expect(report.silenceCount, equals(0));
      expect(report.backpressureCount, equals(2));
      expect(report.writerBackpressureRejects, equals(1));
      expect(report.providerFramesZeroFilled, equals(0));
      expect(report.workerThreadDistinct, isTrue);
      expect(report.ownerDispatchCalls, equals(0));
      expect(report.kotlinAcceptedChecksumHex, equals(_kChecksumHex));
      expect(report.nativeAcceptedChecksumHex, equals(_kChecksumHex));
      expect(report.nativeOutputReadChecksumHex, equals(_kChecksumHex));

      // Getters
      expect(report.checksumsMatch, isTrue);
      expect(report.allNativeLanesPass, isTrue);

      // Serialization round-trip.
      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['marker'], equals(_kPassMarker));
      expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
      final roundTrip = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        serialized,
      );
      expect(roundTrip, equals(report));
    });

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'status': 'checksum_identity_mismatch',
          'marker': _kFailMarker,
          'failureReason': 'checksum_identity_mismatch',
          'lastError': 'checksum_identity_mismatch',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.status, equals('checksum_identity_mismatch'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('checksum_identity_mismatch'));
      expect(report.lastError, equals('checksum_identity_mismatch'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [null, 'not_a_map', 12345, 3.14, <Object?>['a']]) {
        final report =
            VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(invalid);
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
      final report = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'marker=$_kPassMarker;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'formatProbeOk=true;'
            'decoderEosReachedOk=true;'
            'asyncWorkerOwnershipOk=true;'
            'controlCommandSerializationOk=true;'
            'realDecoderIngestOk=true;'
            'sourceBackpressureRetryOk=true;'
            'outputBackpressureOk=true;'
            'checksumIdentityOk=true;'
            'frameAccountingOk=true;'
            'seekEpochReanchorOk=true;'
            'noOwnerThreadDispatchOk=true;'
            'foreignThreadRejectedOk=true;'
            'workerJoinOnDestroyOk=true;'
            'idempotentDestroyOk=true;'
            'canonicalProofBoundaryOk=true;'
            'workerThreadDistinct=true;'
            'ownerDispatchCalls=0;'
            'commandsEnqueued=4;'
            'commandsProcessed=4;'
            'commandErrors=0;'
            'silenceCount=0;'
            'backpressureCount=2;'
            'writerBackpressureRejects=1;'
            'providerFramesZeroFilled=0;'
            'expectedFrames=23808;'
            'preSeekFrames=10752;'
            'seekTargetFrame=10752;'
            'totalFramesExtracted=40960;'
            'totalFramesAccepted=23808;'
            'totalFramesRendered=23808;'
            'totalFramesPushed=23808;'
            'totalOutputFramesRead=23808;'
            'kotlinAcceptedChecksumHex=$_kChecksumHex;'
            'nativeAcceptedChecksumHex=$_kChecksumHex;'
            'nativeOutputReadChecksumHex=$_kChecksumHex',
      });

      expect(report.pass, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.asyncWorkerOwnershipOk, isTrue);
      expect(report.workerThreadDistinct, isTrue);
      expect(report.checksumsMatch, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });
  });

  group('allNativeLanesPass verification contract', () {
    test('requires proofBoundary to match canonical constant', () {
      final report = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'proofBoundary': 'shortened_boundary'}),
      );
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires marker to match pass marker constant', () {
      final report = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'marker': _kFailMarker}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires every lane boolean to be true', () {
      for (final lane in _kLaneKeys) {
        final report = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
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
      final notDistinct = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'workerThreadDistinct': false}),
      );
      expect(notDistinct.allNativeLanesPass, isFalse);

      final ownerDispatched = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'ownerDispatchCalls': 1}),
      );
      expect(ownerDispatched.allNativeLanesPass, isFalse);
    });

    test('requires exactly four serialized commands with zero errors', () {
      final unbalanced = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'commandsProcessed': 3}),
      );
      expect(unbalanced.allNativeLanesPass, isFalse);

      final errored = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'commandErrors': 1}),
      );
      expect(errored.allNativeLanesPass, isFalse);
    });

    test('requires checksum identity across all three checksums', () {
      final mismatch = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({
          'nativeOutputReadChecksumHex': '0000000022222222',
        }),
      );
      expect(mismatch.checksumsMatch, isFalse);
      expect(mismatch.allNativeLanesPass, isFalse);

      final empty = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'kotlinAcceptedChecksumHex': ''}),
      );
      expect(empty.checksumsMatch, isFalse);
      expect(empty.allNativeLanesPass, isFalse);
    });

    test('requires lockstep frame accounting on the expected timeline', () {
      final report = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'totalOutputFramesRead': 23000}),
      );
      expect(report.allNativeLanesPass, isFalse);

      final zero = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({
          'expectedFrames': 0,
          'totalFramesAccepted': 0,
          'totalFramesRendered': 0,
          'totalFramesPushed': 0,
          'totalOutputFramesRead': 0,
        }),
      );
      expect(zero.allNativeLanesPass, isFalse);
    });

    test('requires the seek target to equal the pre-seek budget frame', () {
      final report = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'seekTargetFrame': 10496}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires observed backpressure on both rings', () {
      final noOutputBp = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'backpressureCount': 0}),
      );
      expect(noOutputBp.allNativeLanesPass, isFalse);

      final noSourceBp = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'writerBackpressureRejects': 0}),
      );
      expect(noSourceBp.allNativeLanesPass, isFalse);
    });

    test('requires zero zero-fill and zero silence in the identity', () {
      final zeroFilled = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'providerFramesZeroFilled': 1}),
      );
      expect(zeroFilled.allNativeLanesPass, isFalse);

      final silent = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'silenceCount': 1}),
      );
      expect(silent.allNativeLanesPass, isFalse);
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

      final report = await VGAsyncRuntimeQueueRealDecoderSmokeReport
          .runAsyncRuntimeQueueRealDecoderSmoke(
        sourcePath: '/tmp/clip_B.mov',
      );

      expect(capturedMethod, equals('runAsyncRuntimeQueueRealDecoderSmoke'));
      expect(
        capturedArgs,
        equals(<String, Object?>{
          'sourcePath': '/tmp/clip_B.mov',
          'durationSec': 1.0,
          'seekTargetSec': 0.35,
          'preSeekBudgetSec': 0.25,
          'postSeekBudgetSec': 0.30,
          'sourceRingCapacityFrames': 2048,
          'outputRingCapacityFrames': 1024,
          'maxFramesPerMix': 256,
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

      final report = await VGAsyncRuntimeQueueRealDecoderSmokeReport
          .runAsyncRuntimeQueueRealDecoderSmoke(
        sourcePath: '/tmp/other.mov',
        durationSec: 1.5,
        seekTargetSec: 0.5,
        preSeekBudgetSec: 0.3,
        postSeekBudgetSec: 0.4,
        sourceRingCapacityFrames: 4096,
        outputRingCapacityFrames: 2048,
        maxFramesPerMix: 128,
        timeout: const Duration(seconds: 15),
      );

      expect(
        capturedArgs,
        equals(<String, Object?>{
          'sourcePath': '/tmp/other.mov',
          'durationSec': 1.5,
          'seekTargetSec': 0.5,
          'preSeekBudgetSec': 0.3,
          'postSeekBudgetSec': 0.4,
          'sourceRingCapacityFrames': 4096,
          'outputRingCapacityFrames': 2048,
          'maxFramesPerMix': 128,
          'deadlineMs': 15000,
        }),
      );
      expect(report.pass, isTrue);
    });

    test('PlatformException produces fail-shaped report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw PlatformException(
          code: 'P4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_SMOKE_BUSY',
          message: 'runAsyncRuntimeQueueRealDecoderSmoke: busy',
        );
      });

      final report = await VGAsyncRuntimeQueueRealDecoderSmokeReport
          .runAsyncRuntimeQueueRealDecoderSmoke(sourcePath: '/tmp/x.mov');

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_SMOKE_BUSY',
        ),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('missing plugin produces unsupported fail-shaped report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw MissingPluginException('no implementation');
      });

      final report = await VGAsyncRuntimeQueueRealDecoderSmokeReport
          .runAsyncRuntimeQueueRealDecoderSmoke(sourcePath: '/tmp/x.mov');

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

      final report = await VGAsyncRuntimeQueueRealDecoderSmokeReport
          .runAsyncRuntimeQueueRealDecoderSmoke(
        sourcePath: '/tmp/x.mov',
        timeout: const Duration(milliseconds: 10),
      );

      expect(report.pass, isFalse);
      expect(report.failureReason, equals('timeout'));
      expect(report.lastError, contains('timeout'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('generic exception produces fail-shaped report', () async {
      final report = await VGAsyncRuntimeQueueRealDecoderSmokeReport
          .runAsyncRuntimeQueueRealDecoderSmoke(
        sourcePath: '/tmp/x.mov',
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
      final reportA = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap(),
      );
      final reportB = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(reportA, equals(reportB));
      expect(reportA.hashCode, equals(reportB.hashCode));
      expect(
        reportA.toString(),
        contains('VGAsyncRuntimeQueueRealDecoderSmokeReport('),
      );
    });

    test('different reports do not compare equal', () {
      final reportA = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'totalFramesAccepted': 23808}),
      );
      final reportB = VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(
        _createSampleRawMap({'totalFramesAccepted': 20000}),
      );

      expect(reportA, isNot(equals(reportB)));
    });
  });
}
