// vg_async_runtime_queue_audiotrack_sink_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-ASYNC-RUNTIME-QUEUE-AUDIOTRACK-SINK:
// Android True-DAG Phase 4 async runtime queue output ring to Kotlin-owned
// muted AudioTrack sink Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'kotlin_owned_muted_audiotrack_sink_on_async_runtime_queue_diagnostic_proof_only_real_decoder_to_async_runtime_queue_scheduler_output_ring_to_muted_audiotrack_mode_stream_write_accounting_worker_owned_clock_and_coordinator_kotlin_owned_audiotrack_lifecycle_writes_reads_telemetry_deadlines_cleanup_write_non_blocking_only_playback_head_and_audio_timestamp_diagnostic_telemetry_and_bounded_sink_write_gating_only_never_native_or_product_media_clock_no_audible_output_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_realtime_rate_claim_no_fleet_claim_no_product_editor_app_wiring_no_export_route_no_streaming_cache_no_ios_no_cpp_primitive_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_SINK_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_SINK_SMOKE_FAIL';
const _kChecksumHex = '00000000abcdef12';

const _kLaneKeys = <String>[
  // X1-equivalent lanes.
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
  // X2 sink lanes.
  'audioTrackInitOk',
  'mutedOutputOk',
  'sinkWriteAccountingOk',
  'playbackHeadProgressionOk',
  'seekSinkEpochResetOk',
  'ownerThreadAffinityOk',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{for (final lane in _kLaneKeys) lane: true};

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
    'framesReadFromRing': 23808,
    'framesWrittenToSink': 23808,
    'residualFramesAtEnd': 0,
    'framesWrittenBeforeSeek': 10752,
    'playbackHeadAtSeek': 9216,
    'framesDiscardedInSinkAtSeek': 1536,
    'playbackHeadFinal': 11520,
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
    'providerFramesZeroFilled': 0,
    'workerThreadDistinct': true,
    'ownerDispatchCalls': 0,
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'kotlinSinkChecksumHex': _kChecksumHex,
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeOutputReadChecksumHex': _kChecksumHex,
    'maxFramesPerMix': 256,
    'zeroWriteCount': 12,
    'partialWriteCount': 3,
    'underrunBaseline': 0,
    'underrunFinal': 0,
    'underrunDelta': 0,
    'audioTimestampAttemptCount': 2,
    'audioTimestampSuccessCount': 2,
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
    'details':
        'seekAcceptedFrame=10752|framesDiscardedInSinkAtSeek=1536|expectedFrames=23808',
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

  group('VGAsyncRuntimeQueueAudioTrackSinkSmokeReport fromMap and toMap', () {
    test('pass report parses all lanes, metrics, and fields cleanly', () {
      final report = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.marker, equals(_kPassMarker));
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.failureReason, isEmpty);
      expect(report.lastError, isEmpty);
      expect(report.details, contains('framesDiscardedInSinkAtSeek=1536'));

      // X1-equivalent lanes (15 lanes).
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

      // X2 sink lanes (6 lanes).
      expect(report.audioTrackInitOk, isTrue);
      expect(report.mutedOutputOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.playbackHeadProgressionOk, isTrue);
      expect(report.seekSinkEpochResetOk, isTrue);
      expect(report.ownerThreadAffinityOk, isTrue);

      // Metrics.
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
      expect(report.framesReadFromRing, equals(23808));
      expect(report.framesWrittenToSink, equals(23808));
      expect(report.residualFramesAtEnd, equals(0));
      expect(report.framesWrittenBeforeSeek, equals(10752));
      expect(report.playbackHeadAtSeek, equals(9216));
      expect(report.framesDiscardedInSinkAtSeek, equals(1536));
      expect(report.playbackHeadFinal, equals(11520));
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
      expect(report.kotlinSinkChecksumHex, equals(_kChecksumHex));
      expect(report.nativeAcceptedChecksumHex, equals(_kChecksumHex));
      expect(report.nativeOutputReadChecksumHex, equals(_kChecksumHex));

      // Getters.
      expect(report.checksumsMatch, isTrue);
      expect(report.sinkAccountingBalanced, isTrue);
      expect(report.allNativeLanesPass, isTrue);

      // Serialization round-trip.
      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['marker'], equals(_kPassMarker));
      expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
      final roundTrip = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        serialized,
      );
      expect(roundTrip, equals(report));
    });

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'status': 'sink_write_accounting_mismatch',
          'marker': _kFailMarker,
          'failureReason': 'sink_write_accounting_mismatch',
          'lastError': 'sink_write_accounting_mismatch',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.status, equals('sink_write_accounting_mismatch'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('sink_write_accounting_mismatch'));
      expect(report.lastError, equals('sink_write_accounting_mismatch'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a'],
      ]) {
        final report = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
          invalid,
        );
        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
        expect(report.proofBoundary, isEmpty);
        expect(report.status, equals('fail'));
        expect(report.marker, equals(_kFailMarker));
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.allNativeLanesPass, isFalse);
        expect(report.totalFramesAccepted, equals(0));
        expect(report.framesWrittenToSink, equals(0));
        expect(report.residualFramesAtEnd, equals(-1));
        expect(report.ownerDispatchCalls, equals(-1));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final report = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap({
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
            'audioTrackInitOk=true;'
            'mutedOutputOk=true;'
            'sinkWriteAccountingOk=true;'
            'playbackHeadProgressionOk=true;'
            'seekSinkEpochResetOk=true;'
            'ownerThreadAffinityOk=true;'
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
            'framesReadFromRing=23808;'
            'framesWrittenToSink=23808;'
            'residualFramesAtEnd=0;'
            'framesWrittenBeforeSeek=10752;'
            'playbackHeadAtSeek=9216;'
            'framesDiscardedInSinkAtSeek=1536;'
            'playbackHeadFinal=11520;'
            'kotlinAcceptedChecksumHex=$_kChecksumHex;'
            'kotlinSinkChecksumHex=$_kChecksumHex;'
            'nativeAcceptedChecksumHex=$_kChecksumHex;'
            'nativeOutputReadChecksumHex=$_kChecksumHex',
      });

      expect(report.pass, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.asyncWorkerOwnershipOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.workerThreadDistinct, isTrue);
      expect(report.checksumsMatch, isTrue);
      expect(report.sinkAccountingBalanced, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });
  });

  group('allNativeLanesPass verification contract', () {
    test('requires proofBoundary to match canonical constant', () {
      final report = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'proofBoundary': 'shortened_boundary'}),
      );
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires marker to match pass marker constant', () {
      final report = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'marker': _kFailMarker}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires every lane boolean to be true', () {
      for (final lane in _kLaneKeys) {
        final report = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
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
      final notDistinct = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'workerThreadDistinct': false}),
      );
      expect(notDistinct.allNativeLanesPass, isFalse);

      final ownerDispatched =
          VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
            _createSampleRawMap({'ownerDispatchCalls': 1}),
          );
      expect(ownerDispatched.allNativeLanesPass, isFalse);
    });

    test('requires exactly four serialized commands with zero errors', () {
      final unbalanced = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'commandsProcessed': 3}),
      );
      expect(unbalanced.allNativeLanesPass, isFalse);

      final errored = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'commandErrors': 1}),
      );
      expect(errored.allNativeLanesPass, isFalse);
    });

    test('requires checksum identity across all four checksums', () {
      final readMismatch = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({
          'nativeOutputReadChecksumHex': '0000000022222222',
        }),
      );
      expect(readMismatch.checksumsMatch, isFalse);
      expect(readMismatch.allNativeLanesPass, isFalse);

      final sinkMismatch = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'kotlinSinkChecksumHex': '0000000033333333'}),
      );
      expect(sinkMismatch.checksumsMatch, isFalse);
      expect(sinkMismatch.allNativeLanesPass, isFalse);

      final empty = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'kotlinSinkChecksumHex': ''}),
      );
      expect(empty.checksumsMatch, isFalse);
      expect(empty.allNativeLanesPass, isFalse);
    });

    test('requires lockstep frame accounting on the expected timeline', () {
      final report = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'totalOutputFramesRead': 23000}),
      );
      expect(report.allNativeLanesPass, isFalse);

      final zero = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({
          'expectedFrames': 0,
          'totalFramesAccepted': 0,
          'totalFramesRendered': 0,
          'totalFramesPushed': 0,
          'totalOutputFramesRead': 0,
          'framesReadFromRing': 0,
          'framesWrittenToSink': 0,
        }),
      );
      expect(zero.allNativeLanesPass, isFalse);
    });

    test('requires the lossless sink write accounting identity', () {
      final shortWrite = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'framesWrittenToSink': 23552}),
      );
      expect(shortWrite.sinkAccountingBalanced, isFalse);
      expect(shortWrite.allNativeLanesPass, isFalse);

      final residual = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'residualFramesAtEnd': 256}),
      );
      expect(residual.sinkAccountingBalanced, isFalse);
      expect(residual.allNativeLanesPass, isFalse);
    });

    test('requires non-negative sink discard accounting at seek', () {
      final report = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'framesDiscardedInSinkAtSeek': -1}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires final playback head progression in the sink epoch', () {
      final report = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'playbackHeadFinal': 0}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires the seek target to equal the pre-seek budget frame', () {
      final report = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'seekTargetFrame': 10496}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires observed backpressure on both rings', () {
      final noOutputBp = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'backpressureCount': 0}),
      );
      expect(noOutputBp.allNativeLanesPass, isFalse);

      final noSourceBp = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'writerBackpressureRejects': 0}),
      );
      expect(noSourceBp.allNativeLanesPass, isFalse);
    });

    test('requires zero zero-fill and zero silence in the identity', () {
      final zeroFilled = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'providerFramesZeroFilled': 1}),
      );
      expect(zeroFilled.allNativeLanesPass, isFalse);

      final silent = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
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

      final report =
          await VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.runAsyncRuntimeQueueAudioTrackSinkSmoke(
            sourcePath: '/tmp/clip_B.mov',
          );

      expect(capturedMethod, equals('runAsyncRuntimeQueueAudioTrackSinkSmoke'));
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

      final report =
          await VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.runAsyncRuntimeQueueAudioTrackSinkSmoke(
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
          code: 'P4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_SINK_SMOKE_BUSY',
          message: 'runAsyncRuntimeQueueAudioTrackSinkSmoke: busy',
        );
      });

      final report =
          await VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.runAsyncRuntimeQueueAudioTrackSinkSmoke(
            sourcePath: '/tmp/x.mov',
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_SINK_SMOKE_BUSY',
        ),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('missing plugin produces unsupported fail-shaped report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw MissingPluginException('no implementation');
      });

      final report =
          await VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.runAsyncRuntimeQueueAudioTrackSinkSmoke(
            sourcePath: '/tmp/x.mov',
          );

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
          await VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.runAsyncRuntimeQueueAudioTrackSinkSmoke(
            sourcePath: '/tmp/x.mov',
            timeout: const Duration(milliseconds: 10),
          );

      expect(report.pass, isFalse);
      expect(report.failureReason, equals('timeout'));
      expect(report.lastError, contains('timeout'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('generic exception produces fail-shaped report', () async {
      final report =
          await VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.runAsyncRuntimeQueueAudioTrackSinkSmoke(
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
      final reportA = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap(),
      );
      final reportB = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(reportA, equals(reportB));
      expect(reportA.hashCode, equals(reportB.hashCode));
      expect(
        reportA.toString(),
        contains('VGAsyncRuntimeQueueAudioTrackSinkSmokeReport('),
      );
    });

    test('different reports do not compare equal', () {
      final reportA = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'framesWrittenToSink': 23808}),
      );
      final reportB = VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({'framesWrittenToSink': 20000}),
      );

      expect(reportA, isNot(equals(reportB)));
    });
  });
}
