// vg_audiotrack_output_sink_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-AUDIOTRACK-OUTPUT-SINK-WRITE
// (P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice I): Android True-DAG Phase 4
// AudioTrack output sink Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'kotlin_owned_android_audiotrack_output_sink_write_diagnostic_proof_only_existing_h2_closed_loop_native_output_ring_source_no_cpp_os_sink_no_native_wall_clock_read_frame_derived_virtual_ticks_only_system_nanotime_telemetry_only_audio_timestamp_conditional_telemetry_only_playback_head_consumption_assertion_only_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_clock_sync_no_av_sync_no_pause_resume_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_offload_no_low_latency_mode_no_aaudio_no_opensl_no_oboe_no_dead_object_recovery_no_production_source_node_wiring_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim_no_in_band_dispose_cancellation_proof_detach_cancellation_source_audited_invariant_only';

const _kPassMarker = 'ANDROID_DAG_PHASE4_AUDIOTRACK_OUTPUT_SINK_SMOKE_PASS';
const _kFailMarker = 'ANDROID_DAG_PHASE4_AUDIOTRACK_OUTPUT_SINK_SMOKE_FAIL';
const _kChecksumHex = '0000000012345678';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'formatProbeOk': true,
    'audioTrackInitOk': true,
    'prerollOk': true,
    'sinkWriteAccountingOk': true,
    'checksumIdentityOk': true,
    'playbackHeadMonotonicOk': true,
    'playbackHeadAdvancedOk': true,
    'headNeverExceedsWrittenOk': true,
    'tailDrainedOk': true,
    'seekEpochAccountingOk': true,
    'noUnderrunOk': true,
    'noSilenceOk': true,
    'noRingPushShortfallOk': true,
    'zeroNativeSteadyStateAllocationOk': true,
    'ownerThreadOk': true,
    'lifecycleOk': true,
    'canonical': true,
    'cancellationPollingLiveOk': true,
    'audioTimestampAvailable': true,
    'audioTimestampValidOk': true,
  };

  final metrics = <String, Object?>{
    'cancellationPollCount': 42,
    'sampleRate': 48000,
    'channelCount': 2,
    'audioTimestampAttemptCount': 10,
    'audioTimestampSuccessCount': 8,
    'playbackHeadFinal': 16384,
    'framesWrittenTotal': 16384,
    'framesReadFromRingTotal': 16384,
    'partialWriteCount': 0,
    'zeroWriteCount': 0,
    'getUnderrunCount': 0,
    'bufferSizeInFrames': 4096,
    'bufferCapacityInFrames': 8192,
    'maxHeadLagFrames': 512,
    'finalHeadLagFrames': 0,
    'prerollFrames': 512,
    'seekAcceptedFrame': 4096,
    'totalFramesAccepted': 16384,
    'totalOutputFramesDrained': 16384,
    'dispatchCount': 64,
    'nativeOutputDrainChecksumHex': _kChecksumHex,
    'kotlinSinkChecksumHex': _kChecksumHex,
    'nativeLastStatus': 'drained',
  };

  final raw = <String, String>{
    'status': 'PASS',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'sampleRate=48000|channelCount=2|epoch0FramesWritten=4096|epoch1FramesWritten=12288',
    'cancellationPollingLiveOk': 'true',
    'audioTimestampAvailable': 'true',
    'audioTimestampValidOk': 'true',
    'cancellationPollCount': '42',
    'sampleRate': '48000',
    'channelCount': '2',
    'audioTimestampAttemptCount': '10',
    'audioTimestampSuccessCount': '8',
    'playbackHeadFinal': '16384',
    'framesWrittenTotal': '16384',
    'framesReadFromRingTotal': '16384',
    'partialWriteCount': '0',
    'zeroWriteCount': '0',
    'getUnderrunCount': '0',
    'bufferSizeInFrames': '4096',
    'bufferCapacityInFrames': '8192',
    'maxHeadLagFrames': '512',
    'finalHeadLagFrames': '0',
    'prerollFrames': '512',
    'seekAcceptedFrame': '4096',
    'totalFramesAccepted': '16384',
    'totalOutputFramesDrained': '16384',
    'dispatchCount': '64',
    'nativeOutputDrainChecksumHex': _kChecksumHex,
    'kotlinSinkChecksumHex': _kChecksumHex,
    'nativeLastStatus': 'drained',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'sampleRate=48000|channelCount=2|epoch0FramesWritten=4096|epoch1FramesWritten=12288',
    'detachCancellationProven': false,
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

VGAudioTrackOutputSinkSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGAudioTrackOutputSinkSmokeReport.fromMap(_createSampleRawMap(overrides));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGAudioTrackOutputSinkSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGAudioTrackOutputSinkSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.status, equals('pass'));
        expect(report.marker, equals(_kPassMarker));
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.failureReason, isEmpty);
        expect(report.lastError, isEmpty);
        expect(report.details, contains('sampleRate=48000'));
        expect(report.detachCancellationProven, isFalse);

        // Physically asserted lanes (17 lanes)
        expect(report.formatProbeOk, isTrue);
        expect(report.audioTrackInitOk, isTrue);
        expect(report.prerollOk, isTrue);
        expect(report.sinkWriteAccountingOk, isTrue);
        expect(report.checksumIdentityOk, isTrue);
        expect(report.playbackHeadMonotonicOk, isTrue);
        expect(report.playbackHeadAdvancedOk, isTrue);
        expect(report.headNeverExceedsWrittenOk, isTrue);
        expect(report.tailDrainedOk, isTrue);
        expect(report.seekEpochAccountingOk, isTrue);
        expect(report.noUnderrunOk, isTrue);
        expect(report.noSilenceOk, isTrue);
        expect(report.noRingPushShortfallOk, isTrue);
        expect(report.zeroNativeSteadyStateAllocationOk, isTrue);
        expect(report.ownerThreadOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.canonical, isTrue);

        // Conditional / telemetry lanes (3 lanes)
        expect(report.cancellationPollingLiveOk, isTrue);
        expect(report.audioTimestampAvailable, isTrue);
        expect(report.audioTimestampValidOk, isTrue);

        // Metrics (23 metrics)
        expect(report.cancellationPollCount, equals(42));
        expect(report.sampleRate, equals(48000));
        expect(report.channelCount, equals(2));
        expect(report.audioTimestampAttemptCount, equals(10));
        expect(report.audioTimestampSuccessCount, equals(8));
        expect(report.playbackHeadFinal, equals(16384));
        expect(report.framesWrittenTotal, equals(16384));
        expect(report.framesReadFromRingTotal, equals(16384));
        expect(report.partialWriteCount, equals(0));
        expect(report.zeroWriteCount, equals(0));
        expect(report.getUnderrunCount, equals(0));
        expect(report.bufferSizeInFrames, equals(4096));
        expect(report.bufferCapacityInFrames, equals(8192));
        expect(report.maxHeadLagFrames, equals(512));
        expect(report.finalHeadLagFrames, equals(0));
        expect(report.prerollFrames, equals(512));
        expect(report.seekAcceptedFrame, equals(4096));
        expect(report.totalFramesAccepted, equals(16384));
        expect(report.totalOutputFramesDrained, equals(16384));
        expect(report.dispatchCount, equals(64));
        expect(report.nativeOutputDrainChecksumHex, equals(_kChecksumHex));
        expect(report.kotlinSinkChecksumHex, equals(_kChecksumHex));
        expect(report.nativeLastStatus, equals('drained'));

        // Getters
        expect(report.checksumsMatch, isTrue);
        expect(report.allNativeLanesPass, isTrue);

        // Serialization
        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['status'], equals('pass'));
        expect(serialized['marker'], equals(_kPassMarker));
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(serialized['detachCancellationProven'], isFalse);
        expect(serialized['lastError'], equals(''));
        expect(serialized['lanes'], equals(report.lanes));
        expect(serialized['metrics'], equals(report.metrics));
        expect(serialized['raw'], equals(report.raw));

        final roundTrip = VGAudioTrackOutputSinkSmokeReport.fromMap(serialized);
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAudioTrackOutputSinkSmokeReport.fromMap(
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
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a', 'b'],
      ]) {
        final report = VGAudioTrackOutputSinkSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
        expect(report.proofBoundary, isEmpty);
        expect(report.status, equals('fail'));
        expect(report.marker, equals(_kFailMarker));
        expect(report.detachCancellationProven, isFalse);
        expect(
          report.raw,
          equals(const <String, String>{'reason': 'native_result_not_a_map'}),
        );
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.allNativeLanesPass, isFalse);
        expect(report.totalFramesAccepted, equals(0));
        expect(report.totalOutputFramesDrained, equals(0));
        expect(report.getUnderrunCount, equals(-1));
        expect(report.finalHeadLagFrames, equals(-1));
        expect(report.seekAcceptedFrame, equals(-1));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGAudioTrackOutputSinkSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'marker=$_kPassMarker;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'formatProbeOk=true;'
            'audioTrackInitOk=true;'
            'prerollOk=true;'
            'sinkWriteAccountingOk=true;'
            'checksumIdentityOk=true;'
            'playbackHeadMonotonicOk=true;'
            'playbackHeadAdvancedOk=true;'
            'headNeverExceedsWrittenOk=true;'
            'tailDrainedOk=true;'
            'seekEpochAccountingOk=true;'
            'noUnderrunOk=true;'
            'noSilenceOk=true;'
            'noRingPushShortfallOk=true;'
            'zeroNativeSteadyStateAllocationOk=true;'
            'ownerThreadOk=true;'
            'lifecycleOk=true;'
            'canonical=true;'
            'cancellationPollingLiveOk=true;'
            'audioTimestampAvailable=true;'
            'audioTimestampValidOk=true;'
            'cancellationPollCount=42;'
            'sampleRate=48000;'
            'channelCount=2;'
            'audioTimestampAttemptCount=10;'
            'audioTimestampSuccessCount=8;'
            'playbackHeadFinal=16384;'
            'framesWrittenTotal=16384;'
            'framesReadFromRingTotal=16384;'
            'partialWriteCount=0;'
            'zeroWriteCount=0;'
            'getUnderrunCount=0;'
            'bufferSizeInFrames=4096;'
            'bufferCapacityInFrames=8192;'
            'maxHeadLagFrames=512;'
            'finalHeadLagFrames=0;'
            'prerollFrames=512;'
            'seekAcceptedFrame=4096;'
            'totalFramesAccepted=16384;'
            'totalOutputFramesDrained=16384;'
            'dispatchCount=64;'
            'nativeOutputDrainChecksumHex=$_kChecksumHex;'
            'kotlinSinkChecksumHex=$_kChecksumHex;'
            'nativeLastStatus=drained',
        'lanes': const <String, Object?>{},
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.formatProbeOk, isTrue);
      expect(reportFromRaw.audioTrackInitOk, isTrue);
      expect(reportFromRaw.prerollOk, isTrue);
      expect(reportFromRaw.sinkWriteAccountingOk, isTrue);
      expect(reportFromRaw.checksumIdentityOk, isTrue);
      expect(reportFromRaw.playbackHeadMonotonicOk, isTrue);
      expect(reportFromRaw.playbackHeadAdvancedOk, isTrue);
      expect(reportFromRaw.headNeverExceedsWrittenOk, isTrue);
      expect(reportFromRaw.tailDrainedOk, isTrue);
      expect(reportFromRaw.seekEpochAccountingOk, isTrue);
      expect(reportFromRaw.noUnderrunOk, isTrue);
      expect(reportFromRaw.noSilenceOk, isTrue);
      expect(reportFromRaw.noRingPushShortfallOk, isTrue);
      expect(reportFromRaw.zeroNativeSteadyStateAllocationOk, isTrue);
      expect(reportFromRaw.ownerThreadOk, isTrue);
      expect(reportFromRaw.lifecycleOk, isTrue);
      expect(reportFromRaw.canonical, isTrue);
      expect(reportFromRaw.cancellationPollingLiveOk, isTrue);
      expect(reportFromRaw.audioTimestampAvailable, isTrue);
      expect(reportFromRaw.audioTimestampValidOk, isTrue);
      expect(reportFromRaw.sampleRate, equals(48000));
      expect(reportFromRaw.channelCount, equals(2));
      expect(reportFromRaw.playbackHeadFinal, equals(16384));
      expect(reportFromRaw.framesWrittenTotal, equals(16384));
      expect(reportFromRaw.framesReadFromRingTotal, equals(16384));
      expect(reportFromRaw.finalHeadLagFrames, equals(0));
      expect(reportFromRaw.prerollFrames, equals(512));
      expect(reportFromRaw.totalFramesAccepted, equals(16384));
      expect(reportFromRaw.totalOutputFramesDrained, equals(16384));
      expect(reportFromRaw.dispatchCount, equals(64));
      expect(reportFromRaw.nativeOutputDrainChecksumHex, equals(_kChecksumHex));
      expect(reportFromRaw.kotlinSinkChecksumHex, equals(_kChecksumHex));
      expect(reportFromRaw.nativeLastStatus, equals('drained'));
      expect(reportFromRaw.checksumsMatch, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in lanes and metrics', () {
      final report = VGAudioTrackOutputSinkSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'lanes': const <String, Object?>{
          'formatProbeOk': 'true',
          'audioTrackInitOk': 'pass',
          'prerollOk': 'ok',
          'sinkWriteAccountingOk': 'success',
          'audioTimestampAvailable': 'false',
        },
      });

      expect(report.formatProbeOk, isTrue);
      expect(report.audioTrackInitOk, isTrue);
      expect(report.prerollOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.audioTimestampAvailable, isFalse);
    });

    test('nested lane and metric precedence over top-level or raw fields', () {
      final report = VGAudioTrackOutputSinkSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'formatProbeOk': false,
        'sampleRate': 22050,
        'lanes': const <String, Object?>{'formatProbeOk': true},
        'metrics': const <String, Object?>{'sampleRate': 48000},
        'raw': const <String, String>{
          'formatProbeOk': 'false',
          'sampleRate': '44100',
        },
      });

      expect(report.formatProbeOk, isTrue);
      expect(report.sampleRate, equals(48000));
    });

    test(
      'audioTimestampAvailable=false with audioTimestampValidOk=true still passes',
      () {
        final reportWithoutTimestamp = _createSampleReport({
          'audioTimestampAvailable': false,
          'audioTimestampAttemptCount': 10,
          'audioTimestampSuccessCount': 0,
          'audioTimestampValidOk': true,
        });

        expect(reportWithoutTimestamp.audioTimestampAvailable, isFalse);
        expect(reportWithoutTimestamp.audioTimestampValidOk, isTrue);
        expect(reportWithoutTimestamp.allNativeLanesPass, isTrue);
      },
    );

    test('audioTimestampValidOk=false fails allNativeLanesPass', () {
      final reportInvalidTimestamp = _createSampleReport({
        'audioTimestampValidOk': false,
      });

      expect(reportInvalidTimestamp.audioTimestampValidOk, isFalse);
      expect(reportInvalidTimestamp.allNativeLanesPass, isFalse);
    });

    test('cancellationPollingLiveOk=false fails allNativeLanesPass', () {
      final reportNoCancelPoll = _createSampleReport({
        'cancellationPollingLiveOk': false,
      });

      expect(reportNoCancelPoll.cancellationPollingLiveOk, isFalse);
      expect(reportNoCancelPoll.allNativeLanesPass, isFalse);
    });

    test('cancellationPollCount=0 fails allNativeLanesPass', () {
      final reportZeroCancelCount = _createSampleReport({
        'cancellationPollCount': 0,
      });

      expect(reportZeroCancelCount.cancellationPollCount, equals(0));
      expect(reportZeroCancelCount.allNativeLanesPass, isFalse);
    });

    test('detachCancellationProven=false is retained and does not fail', () {
      final report = _createSampleReport({'detachCancellationProven': false});

      expect(report.detachCancellationProven, isFalse);
      expect(report.allNativeLanesPass, isTrue);
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
      expect(reportInvalid.allNativeLanesPass, isFalse);

      final reportEmpty = _createSampleReport({'proofBoundary': ''});
      expect(reportEmpty.hasCanonicalProofBoundary, isFalse);
      expect(reportEmpty.allNativeLanesPass, isFalse);
    });
  });

  group('Checksum matching and lane verification', () {
    test('checksumsMatch verifies 2-way non-empty identity and lane ok', () {
      final report = _createSampleReport();
      expect(report.checksumsMatch, isTrue);

      expect(
        _createSampleReport({'kotlinSinkChecksumHex': ''}).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'nativeOutputDrainChecksumHex': '',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'kotlinSinkChecksumHex': 'mismatch',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({'checksumIdentityOk': false}).checksumsMatch,
        isFalse,
      );
    });

    test('checksum mismatch causes allNativeLanesPass to fail', () {
      final reportMismatch = _createSampleReport({
        'kotlinSinkChecksumHex': 'mismatched_hex_1234',
      });
      expect(reportMismatch.checksumsMatch, isFalse);
      expect(reportMismatch.allNativeLanesPass, isFalse);
    });

    test('allNativeLanesPass requires all conditions to hold', () {
      expect(_createSampleReport().allNativeLanesPass, isTrue);

      // Top-level status / marker / pass / proof boundary
      expect(_createSampleReport({'pass': false}).allNativeLanesPass, isFalse);
      expect(
        _createSampleReport({'status': 'fail'}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'marker': _kFailMarker}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'proofBoundary': 'invalid'}).allNativeLanesPass,
        isFalse,
      );

      // Required physically asserted lanes
      expect(
        _createSampleReport({'formatProbeOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'audioTrackInitOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'prerollOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'sinkWriteAccountingOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'checksumIdentityOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'playbackHeadMonotonicOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'playbackHeadAdvancedOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'headNeverExceedsWrittenOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'tailDrainedOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'seekEpochAccountingOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'noUnderrunOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'noSilenceOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'noRingPushShortfallOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'zeroNativeSteadyStateAllocationOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'ownerThreadOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'lifecycleOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'canonical': false}).allNativeLanesPass,
        isFalse,
      );

      // Accounting and metric integrity
      expect(
        _createSampleReport({'sampleRate': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'channelCount': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'playbackHeadFinal': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'framesWrittenTotal': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'framesReadFromRingTotal': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'framesWrittenTotal': 16384,
          'framesReadFromRingTotal': 16000,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'framesReadFromRingTotal': 16384,
          'totalOutputFramesDrained': 16000,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'totalFramesAccepted': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'totalOutputFramesDrained': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'dispatchCount': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'prerollFrames': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'finalHeadLagFrames': 1}).allNativeLanesPass,
        isFalse,
      );

      // Error strings
      expect(
        _createSampleReport({'lastError': 'some_error'}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'lastError': 'none'}).allNativeLanesPass,
        isTrue,
      );
      expect(
        _createSampleReport({'lastError': 'null'}).allNativeLanesPass,
        isTrue,
      );
    });
  });

  group('Value semantics: equality, hashCode, toString', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGAudioTrackOutputSinkSmokeReport('));
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
        {'status': 'fail'},
        {'marker': _kFailMarker},
        {'proofBoundary': 'other_boundary'},
        {'detachCancellationProven': true},
        {'formatProbeOk': false},
        {'audioTrackInitOk': false},
        {'prerollOk': false},
        {'sinkWriteAccountingOk': false},
        {'checksumIdentityOk': false},
        {'playbackHeadMonotonicOk': false},
        {'playbackHeadAdvancedOk': false},
        {'headNeverExceedsWrittenOk': false},
        {'tailDrainedOk': false},
        {'seekEpochAccountingOk': false},
        {'noUnderrunOk': false},
        {'noSilenceOk': false},
        {'noRingPushShortfallOk': false},
        {'zeroNativeSteadyStateAllocationOk': false},
        {'ownerThreadOk': false},
        {'lifecycleOk': false},
        {'canonical': false},
        {'cancellationPollingLiveOk': false},
        {'audioTimestampAvailable': false},
        {'audioTimestampValidOk': false},
        {'cancellationPollCount': 99},
        {'sampleRate': 44100},
        {'channelCount': 1},
        {'audioTimestampAttemptCount': 99},
        {'audioTimestampSuccessCount': 99},
        {'playbackHeadFinal': 999},
        {'framesWrittenTotal': 999},
        {'framesReadFromRingTotal': 999},
        {'partialWriteCount': 5},
        {'zeroWriteCount': 5},
        {'getUnderrunCount': 5},
        {'bufferSizeInFrames': 2048},
        {'bufferCapacityInFrames': 4096},
        {'maxHeadLagFrames': 256},
        {'finalHeadLagFrames': 42},
        {'prerollFrames': 256},
        {'seekAcceptedFrame': 1024},
        {'totalFramesAccepted': 999},
        {'totalOutputFramesDrained': 999},
        {'dispatchCount': 100},
        {'nativeOutputDrainChecksumHex': 'diff'},
        {'kotlinSinkChecksumHex': 'diff'},
        {'nativeLastStatus': 'other'},
        {'lastError': 'some_error'},
        {
          'raw': const <String, String>{'custom': 'diff'},
        },
        {
          'lanes': const <String, Object?>{'custom': false},
        },
        {
          'metrics': const <String, Object?>{'custom': 123},
        },
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group('MethodChannel wrapper: runAndroidDagPhase4AudioTrackOutputSinkSmoke', () {
    test(
      'invokes runAndroidDagPhase4AudioTrackOutputSinkSmoke with correct default args on default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGAudioTrackOutputSinkSmokeReport.runAndroidDagPhase4AudioTrackOutputSinkSmoke(
              sourcePath: '/path/to/test/clip_B.mov',
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4AudioTrackOutputSinkSmoke'),
        );
        expect(
          capturedCall!.arguments,
          equals(<String, Object?>{
            'sourcePath': '/path/to/test/clip_B.mov',
            'durationSec': 1.0,
            'seekTargetSec': 0.35,
            'volume': 0.0,
            'sourceRingCapacityFrames': 8192,
            'outputRingCapacityFrames': 4096,
            'maxFramesPerMix': 256,
            'deadlineMs': 30000,
          }),
        );
        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.allNativeLanesPass, isTrue);
        expect(report.detachCancellationProven, isFalse);
      },
    );

    test('invokes with custom args and timeout on custom channel', () async {
      MethodCall? capturedCall;
      const customChannel = MethodChannel('custom_audiotrack_sink_channel');
      binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGAudioTrackOutputSinkSmokeReport.runAndroidDagPhase4AudioTrackOutputSinkSmoke(
            sourcePath: '/custom/path/clip.mp4',
            durationSec: 1.5,
            seekTargetSec: 0.5,
            volume: 0.5,
            sourceRingCapacityFrames: 16384,
            outputRingCapacityFrames: 8192,
            maxFramesPerMix: 128,
            timeout: const Duration(seconds: 45),
            channel: customChannel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('runAndroidDagPhase4AudioTrackOutputSinkSmoke'),
      );
      expect(
        capturedCall!.arguments,
        equals(<String, Object?>{
          'sourcePath': '/custom/path/clip.mp4',
          'durationSec': 1.5,
          'seekTargetSec': 0.5,
          'volume': 0.5,
          'sourceRingCapacityFrames': 16384,
          'outputRingCapacityFrames': 8192,
          'maxFramesPerMix': 128,
          'deadlineMs': 45000,
        }),
      );
      expect(report.pass, isTrue);
      expect(report.detachCancellationProven, isFalse);
    });

    test('handles PlatformException by returning fallback report', () async {
      const errorChannel = MethodChannel('error_audiotrack_sink_channel');
      binaryMessenger.setMockMethodCallHandler(errorChannel, (call) async {
        throw PlatformException(
          code: 'P4_AUDIOTRACK_OUTPUT_SINK_SMOKE_BUSY',
          message: 'AudioTrack sink diagnostic already running',
        );
      });

      final report =
          await VGAudioTrackOutputSinkSmokeReport.runAndroidDagPhase4AudioTrackOutputSinkSmoke(
            sourcePath: '/dummy/path',
            channel: errorChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(report.detachCancellationProven, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_AUDIOTRACK_OUTPUT_SINK_SMOKE_BUSY:AudioTrack sink diagnostic already running',
        ),
      );
    });

    test('handles TimeoutException by returning fallback report', () async {
      const slowChannel = MethodChannel('slow_audiotrack_sink_channel');
      binaryMessenger.setMockMethodCallHandler(slowChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });

      final report =
          await VGAudioTrackOutputSinkSmokeReport.runAndroidDagPhase4AudioTrackOutputSinkSmoke(
            sourcePath: '/dummy/path',
            timeout: const Duration(milliseconds: 20),
            channel: slowChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(report.detachCancellationProven, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('timeout'));
    });

    test('handles generic Exception by returning fallback report', () async {
      const exChannel = MethodChannel('ex_audiotrack_sink_channel');
      binaryMessenger.setMockMethodCallHandler(exChannel, (call) async {
        throw Exception('Native AudioTrack sink crashed');
      });

      final report =
          await VGAudioTrackOutputSinkSmokeReport.runAndroidDagPhase4AudioTrackOutputSinkSmoke(
            sourcePath: '/dummy/path',
            channel: exChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(report.detachCancellationProven, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('Native AudioTrack sink crashed'));
    });
  });
}
