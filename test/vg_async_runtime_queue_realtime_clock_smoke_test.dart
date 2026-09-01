// vg_async_runtime_queue_realtime_clock_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-ASYNC-RUNTIME-QUEUE-REALTIME-CLOCK-PACING:
// Android True-DAG Phase 4 async runtime queue native worker-owned
// steady_clock realtime pacing Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'kotlin_owned_audiotrack_sink_on_async_runtime_queue_realtime_wall_clock_pacing_proof_only_real_decoder_to_async_runtime_queue_scheduler_output_ring_to_muted_audiotrack_mode_stream_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_write_non_blocking_only_playback_head_and_audio_timestamp_telemetry_only_no_audible_output_no_speaker_route_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_zero_underrun_claim_no_realtime_priority_claim_no_fleet_claim_no_product_editor_app_wiring_no_export_route_no_streaming_cache_no_ios_no_cpp_primitive_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REALTIME_CLOCK_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REALTIME_CLOCK_SMOKE_FAIL';
const _kChecksumHex = '00000000abcdef12';

const _kLaneKeys = <String>[
  'formatProbeOk',
  'decoderEosReachedOk',
  'realtimeWorkerClockOwnershipOk',
  'noCallerSuppliedNativeTimeOk',
  'noOwnerThreadDispatchOk',
  'controlCommandSerializationOk',
  'realDecoderIngestOk',
  'checksumIdentityOk',
  'frameAccountingOk',
  'sinkWriteAccountingOk',
  'audioTrackInitOk',
  'mutedOutputOk',
  'playbackHeadTelemetryOk',
  'realtimeNativeElapsedOk',
  'realtimeBacklogBoundOk',
  'seekEpochReanchorOk',
  'seekSinkEpochResetOk',
  'workerJoinOnDestroyOk',
  'idempotentDestroyOk',
  'canonicalProofBoundaryOk',
  'ownerThreadAffinityOk',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{for (final lane in _kLaneKeys) lane: true};

  // Geometry mirrors the frozen X3 run at 48kHz stereo:
  // preSeekFrames = floor(1.20 * 48000 / 256) * 256 = 57600,
  // postSeekFrames = floor(0.55 * 48000 / 256) * 256 = 26368.
  final metrics = <String, Object?>{
    'sampleRate': 48000,
    'channelCount': 2,
    'pcmEncoding': 2,
    'expectedFrames': 83968,
    'preSeekFrames': 57600,
    'postSeekFrames': 26368,
    'seekTargetFrame': 57600,
    'sourceRingCapacityFrames': 8192,
    'outputRingCapacityFrames': 4096,
    'maxFramesPerMix': 256,
    'preStartFillFrames': 4608,
    'postSeekFillFrames': 4352,
    'nativeRealtimeElapsedMs': 1004,
    'nativeTimingF0': 8192,
    'nativeTimingF1': 56192,
    'maxRenderCursorBacklogUs': 41250,
    'backlogSampleCount': 290,
    'clockDriftSampleCount': 290,
    'workerNoFramesDueWaits': 352,
    'workerStarvedWaits': 4,
    'totalFramesExtracted': 96000,
    'totalFramesAccepted': 83968,
    'totalFramesRendered': 83968,
    'totalFramesPushed': 83968,
    'totalOutputFramesRead': 83968,
    'framesReadFromRing': 83968,
    'framesWrittenToSink': 83968,
    'residualFramesAtEnd': 0,
    'framesWrittenBeforeSeek': 57600,
    'playbackHeadAtSeek': 56576,
    'framesDiscardedInSinkAtSeek': 1024,
    'playbackHeadFinal': 12800,
    'playbackHeadDeltaTelemetryOnly': 12800,
    'underrunDeltaTelemetryOnly': 0,
    'audioTimestampAttemptCount': 2,
    'audioTimestampSuccessCount': 2,
    'framesTruncatedAtSeekBoundary': 512,
    'framesDiscardedAfterBudget': 11520,
    'decoderBenignFormatChangeCount': 0,
    'commandsEnqueued': 2,
    'commandsProcessed': 2,
    'commandErrors': 0,
    'dispatchCount': 328,
    'silenceCount': 0,
    'backpressureCount': 3,
    'writerBackpressureRejects': 5,
    'providerFramesZeroFilled': 0,
    'workerThreadDistinct': true,
    'ownerDispatchCalls': 0,
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'kotlinSinkChecksumHex': _kChecksumHex,
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeOutputReadChecksumHex': _kChecksumHex,
    'zeroWriteCount': 40,
    'partialWriteCount': 6,
    'underrunBaseline': 0,
    'underrunFinal': 0,
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
        'preStartFillFrames=4608|seekAcceptedFrame=57600|'
        'nativeRealtimeElapsedMs=1004|maxRenderCursorBacklogUs=41250',
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

  group('VGAsyncRuntimeQueueRealtimeClockSmokeReport fromMap and toMap', () {
    test('pass report parses all lanes, metrics, and fields cleanly', () {
      final report = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.marker, equals(_kPassMarker));
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.failureReason, isEmpty);
      expect(report.lastError, isEmpty);
      expect(report.details, contains('nativeRealtimeElapsedMs=1004'));

      // Lanes (21 lanes).
      expect(report.formatProbeOk, isTrue);
      expect(report.decoderEosReachedOk, isTrue);
      expect(report.realtimeWorkerClockOwnershipOk, isTrue);
      expect(report.noCallerSuppliedNativeTimeOk, isTrue);
      expect(report.noOwnerThreadDispatchOk, isTrue);
      expect(report.controlCommandSerializationOk, isTrue);
      expect(report.realDecoderIngestOk, isTrue);
      expect(report.checksumIdentityOk, isTrue);
      expect(report.frameAccountingOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.audioTrackInitOk, isTrue);
      expect(report.mutedOutputOk, isTrue);
      expect(report.playbackHeadTelemetryOk, isTrue);
      expect(report.realtimeNativeElapsedOk, isTrue);
      expect(report.realtimeBacklogBoundOk, isTrue);
      expect(report.seekEpochReanchorOk, isTrue);
      expect(report.seekSinkEpochResetOk, isTrue);
      expect(report.workerJoinOnDestroyOk, isTrue);
      expect(report.idempotentDestroyOk, isTrue);
      expect(report.canonicalProofBoundaryOk, isTrue);
      expect(report.ownerThreadAffinityOk, isTrue);

      // Metrics.
      expect(report.sampleRate, equals(48000));
      expect(report.channelCount, equals(2));
      expect(report.expectedFrames, equals(83968));
      expect(report.preSeekFrames, equals(57600));
      expect(report.postSeekFrames, equals(26368));
      expect(report.seekTargetFrame, equals(57600));
      expect(report.sourceRingCapacityFrames, equals(8192));
      expect(report.outputRingCapacityFrames, equals(4096));
      expect(report.maxFramesPerMix, equals(256));
      expect(report.preStartFillFrames, equals(4608));
      expect(report.nativeRealtimeElapsedMs, equals(1004));
      expect(report.nativeTimingF0, equals(8192));
      expect(report.nativeTimingF1, equals(56192));
      expect(report.maxRenderCursorBacklogUs, equals(41250));
      expect(report.backlogSampleCount, equals(290));
      expect(report.workerNoFramesDueWaits, equals(352));
      expect(report.totalFramesExtracted, equals(96000));
      expect(report.totalFramesAccepted, equals(83968));
      expect(report.totalFramesRendered, equals(83968));
      expect(report.totalFramesPushed, equals(83968));
      expect(report.totalOutputFramesRead, equals(83968));
      expect(report.framesReadFromRing, equals(83968));
      expect(report.framesWrittenToSink, equals(83968));
      expect(report.residualFramesAtEnd, equals(0));
      expect(report.framesDiscardedInSinkAtSeek, equals(1024));
      expect(report.playbackHeadDeltaTelemetryOnly, equals(12800));
      expect(report.underrunDeltaTelemetryOnly, equals(0));
      expect(report.audioTimestampAttemptCount, equals(2));
      expect(report.audioTimestampSuccessCount, equals(2));
      expect(report.commandsEnqueued, equals(2));
      expect(report.commandsProcessed, equals(2));
      expect(report.commandErrors, equals(0));
      expect(report.silenceCount, equals(0));
      expect(report.backpressureCount, equals(3));
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
      expect(report.realtimeGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);

      // Serialization round-trip.
      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['marker'], equals(_kPassMarker));
      expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
      final roundTrip = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        serialized,
      );
      expect(roundTrip, equals(report));
    });

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'status': 'realtime_elapsed_gate_failed',
          'marker': _kFailMarker,
          'failureReason': 'realtime_elapsed_gate_failed:512ms',
          'lastError': 'realtime_elapsed_gate_failed:512ms',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.status, equals('realtime_elapsed_gate_failed'));
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals('realtime_elapsed_gate_failed:512ms'),
      );
      expect(report.lastError, equals('realtime_elapsed_gate_failed:512ms'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [null, 'not_a_map', 12345, 3.14, <Object?>['a']]) {
        final report = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
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
        expect(report.nativeRealtimeElapsedMs, equals(-1));
        expect(report.maxRenderCursorBacklogUs, equals(-1));
        expect(report.ownerDispatchCalls, equals(-1));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final report = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'marker=$_kPassMarker;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'formatProbeOk=true;'
            'decoderEosReachedOk=true;'
            'realtimeWorkerClockOwnershipOk=true;'
            'noCallerSuppliedNativeTimeOk=true;'
            'noOwnerThreadDispatchOk=true;'
            'controlCommandSerializationOk=true;'
            'realDecoderIngestOk=true;'
            'checksumIdentityOk=true;'
            'frameAccountingOk=true;'
            'sinkWriteAccountingOk=true;'
            'audioTrackInitOk=true;'
            'mutedOutputOk=true;'
            'playbackHeadTelemetryOk=true;'
            'realtimeNativeElapsedOk=true;'
            'realtimeBacklogBoundOk=true;'
            'seekEpochReanchorOk=true;'
            'seekSinkEpochResetOk=true;'
            'workerJoinOnDestroyOk=true;'
            'idempotentDestroyOk=true;'
            'canonicalProofBoundaryOk=true;'
            'ownerThreadAffinityOk=true;'
            'workerThreadDistinct=true;'
            'ownerDispatchCalls=0;'
            'commandsEnqueued=2;'
            'commandsProcessed=2;'
            'commandErrors=0;'
            'silenceCount=0;'
            'backpressureCount=3;'
            'providerFramesZeroFilled=0;'
            'expectedFrames=83968;'
            'preSeekFrames=57600;'
            'seekTargetFrame=57600;'
            'preStartFillFrames=4608;'
            'nativeRealtimeElapsedMs=1004;'
            'nativeTimingF0=8192;'
            'nativeTimingF1=56192;'
            'maxRenderCursorBacklogUs=41250;'
            'backlogSampleCount=290;'
            'totalFramesExtracted=96000;'
            'totalFramesAccepted=83968;'
            'totalFramesRendered=83968;'
            'totalFramesPushed=83968;'
            'totalOutputFramesRead=83968;'
            'framesReadFromRing=83968;'
            'framesWrittenToSink=83968;'
            'residualFramesAtEnd=0;'
            'framesDiscardedInSinkAtSeek=1024;'
            'playbackHeadDeltaTelemetryOnly=12800;'
            'kotlinAcceptedChecksumHex=$_kChecksumHex;'
            'kotlinSinkChecksumHex=$_kChecksumHex;'
            'nativeAcceptedChecksumHex=$_kChecksumHex;'
            'nativeOutputReadChecksumHex=$_kChecksumHex',
      });

      expect(report.pass, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.realtimeWorkerClockOwnershipOk, isTrue);
      expect(report.noCallerSuppliedNativeTimeOk, isTrue);
      expect(report.workerThreadDistinct, isTrue);
      expect(report.checksumsMatch, isTrue);
      expect(report.sinkAccountingBalanced, isTrue);
      expect(report.realtimeGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });
  });

  group('allNativeLanesPass verification contract', () {
    test('requires proofBoundary to match canonical constant', () {
      final report = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'proofBoundary': 'shortened_boundary'}),
      );
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires marker to match pass marker constant', () {
      final report = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'marker': _kFailMarker}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires every lane boolean to be true', () {
      for (final lane in _kLaneKeys) {
        final report = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
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
      final notDistinct = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'workerThreadDistinct': false}),
      );
      expect(notDistinct.allNativeLanesPass, isFalse);

      final ownerDispatched =
          VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'ownerDispatchCalls': 1}),
          );
      expect(ownerDispatched.allNativeLanesPass, isFalse);
    });

    test('requires exactly two serialized commands with zero errors', () {
      final unbalanced = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'commandsProcessed': 1}),
      );
      expect(unbalanced.allNativeLanesPass, isFalse);

      final errored = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'commandErrors': 1}),
      );
      expect(errored.allNativeLanesPass, isFalse);
    });

    test('requires the native realtime elapsed gate window', () {
      final tooFast = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'nativeRealtimeElapsedMs': 512}),
      );
      expect(tooFast.realtimeGatesHeld, isFalse);
      expect(tooFast.allNativeLanesPass, isFalse);

      final tooSlow = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'nativeRealtimeElapsedMs': 1500}),
      );
      expect(tooSlow.realtimeGatesHeld, isFalse);
      expect(tooSlow.allNativeLanesPass, isFalse);

      final missing = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'nativeRealtimeElapsedMs': -1}),
      );
      expect(missing.realtimeGatesHeld, isFalse);
      expect(missing.allNativeLanesPass, isFalse);
    });

    test('requires the native render-cursor backlog bound', () {
      final overBound = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'maxRenderCursorBacklogUs': 250000}),
      );
      expect(overBound.realtimeGatesHeld, isFalse);
      expect(overBound.allNativeLanesPass, isFalse);

      final noSamples = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'backlogSampleCount': 0}),
      );
      expect(noSamples.realtimeGatesHeld, isFalse);
      expect(noSamples.allNativeLanesPass, isFalse);
    });

    test('does not require backpressure (normal telemetry in X3)', () {
      final noBackpressure =
          VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'backpressureCount': 0}),
          );
      expect(noBackpressure.allNativeLanesPass, isTrue);
    });

    test('requires the pre-start source fill quota', () {
      final report = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'preStartFillFrames': 2048}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires checksum identity across all four checksums', () {
      final readMismatch = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({
          'nativeOutputReadChecksumHex': '0000000022222222',
        }),
      );
      expect(readMismatch.checksumsMatch, isFalse);
      expect(readMismatch.allNativeLanesPass, isFalse);

      final sinkMismatch = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'kotlinSinkChecksumHex': '0000000033333333'}),
      );
      expect(sinkMismatch.checksumsMatch, isFalse);
      expect(sinkMismatch.allNativeLanesPass, isFalse);

      final empty = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'kotlinSinkChecksumHex': ''}),
      );
      expect(empty.checksumsMatch, isFalse);
      expect(empty.allNativeLanesPass, isFalse);
    });

    test('requires lockstep frame accounting on the expected timeline', () {
      final report = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'totalOutputFramesRead': 83000}),
      );
      expect(report.allNativeLanesPass, isFalse);

      final zero = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
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
      final shortWrite = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'framesWrittenToSink': 83712}),
      );
      expect(shortWrite.sinkAccountingBalanced, isFalse);
      expect(shortWrite.allNativeLanesPass, isFalse);

      final residual = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'residualFramesAtEnd': 256}),
      );
      expect(residual.sinkAccountingBalanced, isFalse);
      expect(residual.allNativeLanesPass, isFalse);
    });

    test('requires non-negative sink discard accounting at seek', () {
      final report = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'framesDiscardedInSinkAtSeek': -1}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires telemetry-only playback head progression post-seek', () {
      final report = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'playbackHeadDeltaTelemetryOnly': 0}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires the seek target to equal the pre-seek budget frame', () {
      final report = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'seekTargetFrame': 57344}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires zero zero-fill and zero silence in the identity', () {
      final zeroFilled = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'providerFramesZeroFilled': 1}),
      );
      expect(zeroFilled.allNativeLanesPass, isFalse);

      final silent = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
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
          await VGAsyncRuntimeQueueRealtimeClockSmokeReport.runAsyncRuntimeQueueRealtimeClockSmoke(
            sourcePath: '/tmp/clip_B.mov',
          );

      expect(capturedMethod, equals('runAsyncRuntimeQueueRealtimeClockSmoke'));
      expect(
        capturedArgs,
        equals(<String, Object?>{
          'sourcePath': '/tmp/clip_B.mov',
          'durationSec': 2.0,
          'seekTargetSec': 1.30,
          'preSeekBudgetSec': 1.20,
          'postSeekBudgetSec': 0.55,
          'sourceRingCapacityFrames': 8192,
          'outputRingCapacityFrames': 4096,
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
          await VGAsyncRuntimeQueueRealtimeClockSmokeReport.runAsyncRuntimeQueueRealtimeClockSmoke(
            sourcePath: '/tmp/other.mov',
            durationSec: 1.8,
            seekTargetSec: 1.25,
            preSeekBudgetSec: 1.15,
            postSeekBudgetSec: 0.40,
            sourceRingCapacityFrames: 16384,
            outputRingCapacityFrames: 8192,
            maxFramesPerMix: 512,
            timeout: const Duration(seconds: 20),
          );

      expect(
        capturedArgs,
        equals(<String, Object?>{
          'sourcePath': '/tmp/other.mov',
          'durationSec': 1.8,
          'seekTargetSec': 1.25,
          'preSeekBudgetSec': 1.15,
          'postSeekBudgetSec': 0.40,
          'sourceRingCapacityFrames': 16384,
          'outputRingCapacityFrames': 8192,
          'maxFramesPerMix': 512,
          'deadlineMs': 20000,
        }),
      );
      expect(report.pass, isTrue);
    });

    test('PlatformException produces fail-shaped report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw PlatformException(
          code: 'P4_ASYNC_RUNTIME_QUEUE_REALTIME_CLOCK_SMOKE_BUSY',
          message: 'runAsyncRuntimeQueueRealtimeClockSmoke: busy',
        );
      });

      final report =
          await VGAsyncRuntimeQueueRealtimeClockSmokeReport.runAsyncRuntimeQueueRealtimeClockSmoke(
            sourcePath: '/tmp/x.mov',
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_ASYNC_RUNTIME_QUEUE_REALTIME_CLOCK_SMOKE_BUSY',
        ),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('missing plugin produces unsupported fail-shaped report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw MissingPluginException('no implementation');
      });

      final report =
          await VGAsyncRuntimeQueueRealtimeClockSmokeReport.runAsyncRuntimeQueueRealtimeClockSmoke(
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
          await VGAsyncRuntimeQueueRealtimeClockSmokeReport.runAsyncRuntimeQueueRealtimeClockSmoke(
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
          await VGAsyncRuntimeQueueRealtimeClockSmokeReport.runAsyncRuntimeQueueRealtimeClockSmoke(
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
      final reportA = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap(),
      );
      final reportB = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(reportA, equals(reportB));
      expect(reportA.hashCode, equals(reportB.hashCode));
      expect(
        reportA.toString(),
        contains('VGAsyncRuntimeQueueRealtimeClockSmokeReport('),
      );
    });

    test('different reports do not compare equal', () {
      final reportA = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'nativeRealtimeElapsedMs': 1004}),
      );
      final reportB = VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(
        _createSampleRawMap({'nativeRealtimeElapsedMs': 1100}),
      );

      expect(reportA, isNot(equals(reportB)));
    });
  });
}
