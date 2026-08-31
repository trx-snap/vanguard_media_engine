// vg_multi_source_audio_track_sink_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-MULTI-SOURCE-AUDIOTRACK-SINK
// (P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice K): Android True-DAG Phase 4
// Multi-Source AudioTrack output sink Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'kotlin_owned_android_audiotrack_multi_source_output_sink_write_diagnostic_proof_only_real_decoder_plus_synthetic_second_track_step_driven_closed_loop_native_audio_graph_pipeline_session_no_second_os_decoder_no_cpp_os_sink_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_frame_derived_virtual_ticks_only_system_nanotime_telemetry_only_audio_timestamp_conditional_telemetry_only_playback_head_consumption_assertion_only_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_clock_sync_no_av_sync_audiotrack_pause_flush_for_seek_epoch_only_no_transport_pause_resume_semantics_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_offload_no_low_latency_mode_no_aaudio_no_opensl_no_oboe_no_dead_object_recovery_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_truncation_beyond_budget_non_claim_two_routed_tracks_unit_gain_only_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_joint_tail_flush_diagnostic_only_no_jni_reverse_callbacks_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_source_node_pcm_ingest_topology_anchor_only_no_production_source_node_wiring_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim_no_in_band_dispose_cancellation_proof_detach_cancellation_source_audited_invariant_only';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_SMOKE_FAIL';
const _kChecksumHex = '00000000abcdef12';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'formatProbeOk': true,
    'audioTrackInitOk': true,
    'prerollOk': true,
    'playbackHeadMonotonicOk': true,
    'playbackHeadAdvancedOk': true,
    'playbackHeadBoundedOk': true,
    'sinkWriteAccountingOk': true,
    'seekEpochAccountingOk': true,
    'jointDispatchGateOk': true,
    'jointTailFlushOk': true,
    'twoTrackContributionOk': true,
    'referenceMixChecksumOk': true,
    'nativeDrainChecksumMatchesSinkOk': true,
    'trackFrameAxisLockstepOk': true,
    'mixedOutputFrameAccountingOk': true,
    'zeroNativeSteadyStateAllocationOk': true,
    'ownerThreadOk': true,
    'lifecycleOk': true,
    'canonical': true,
    'cancellationPollingLiveOk': true,
    'audioTimestampAvailable': true,
    'audioTimestampValidOk': true,
  };

  final metrics = <String, Object?>{
    'cancellationPollCount': 48,
    'sampleRate': 48000,
    'channelCount': 2,
    'commonBudgetFrames': 48000,
    'framesTruncatedBeyondBudget': 0,
    'totalFramesExtracted': 48000,
    'playbackHeadFinal': 48000,
    'framesWrittenTotal': 48000,
    'framesReadFromRingTotal': 48000,
    'partialWriteCount': 0,
    'zeroWriteCount': 0,
    'getUnderrunCount': 0,
    'bufferSizeInFrames': 4096,
    'bufferCapacityInFrames': 8192,
    'maxHeadLagFrames': 512,
    'finalHeadLagFrames': 0,
    'prerollFrames': 512,
    'prerollEpochsSatisfied': 2,
    'seekAcceptedFrame': 16800,
    'generatorReanchorCount': 1,
    'track1NonZeroSampleCount': 96000,
    'totalFramesAcceptedTrack0': 48000,
    'totalFramesAcceptedTrack1': 48000,
    'totalOutputFramesDrained': 48000,
    'dispatchCount': 188,
    'audioTimestampAttemptCount': 12,
    'audioTimestampSuccessCount': 10,
    'nativeOutputDrainChecksumHex': _kChecksumHex,
    'kotlinReferenceMixChecksumHex': _kChecksumHex,
    'kotlinSinkChecksumHex': _kChecksumHex,
    'nativeLastStatus': 'drained',
  };

  final raw = <String, String>{
    'status': 'PASS',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'seekAcceptedFrame=16800|commonBudgetFrames=48000',
    'formatProbeOk': 'true',
    'audioTrackInitOk': 'true',
    'prerollOk': 'true',
    'playbackHeadMonotonicOk': 'true',
    'playbackHeadAdvancedOk': 'true',
    'playbackHeadBoundedOk': 'true',
    'sinkWriteAccountingOk': 'true',
    'seekEpochAccountingOk': 'true',
    'jointDispatchGateOk': 'true',
    'jointTailFlushOk': 'true',
    'twoTrackContributionOk': 'true',
    'referenceMixChecksumOk': 'true',
    'nativeDrainChecksumMatchesSinkOk': 'true',
    'trackFrameAxisLockstepOk': 'true',
    'mixedOutputFrameAccountingOk': 'true',
    'zeroNativeSteadyStateAllocationOk': 'true',
    'ownerThreadOk': 'true',
    'lifecycleOk': 'true',
    'canonical': 'true',
    'cancellationPollingLiveOk': 'true',
    'audioTimestampAvailable': 'true',
    'audioTimestampValidOk': 'true',
    'cancellationPollCount': '48',
    'sampleRate': '48000',
    'channelCount': '2',
    'commonBudgetFrames': '48000',
    'framesTruncatedBeyondBudget': '0',
    'totalFramesExtracted': '48000',
    'playbackHeadFinal': '48000',
    'framesWrittenTotal': '48000',
    'framesReadFromRingTotal': '48000',
    'partialWriteCount': '0',
    'zeroWriteCount': '0',
    'getUnderrunCount': '0',
    'bufferSizeInFrames': '4096',
    'bufferCapacityInFrames': '8192',
    'maxHeadLagFrames': '512',
    'finalHeadLagFrames': '0',
    'prerollFrames': '512',
    'prerollEpochsSatisfied': '2',
    'seekAcceptedFrame': '16800',
    'generatorReanchorCount': '1',
    'track1NonZeroSampleCount': '96000',
    'totalFramesAcceptedTrack0': '48000',
    'totalFramesAcceptedTrack1': '48000',
    'totalOutputFramesDrained': '48000',
    'dispatchCount': '188',
    'audioTimestampAttemptCount': '12',
    'audioTimestampSuccessCount': '10',
    'nativeOutputDrainChecksumHex': _kChecksumHex,
    'kotlinReferenceMixChecksumHex': _kChecksumHex,
    'kotlinSinkChecksumHex': _kChecksumHex,
    'nativeLastStatus': 'drained',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'seekAcceptedFrame=16800|commonBudgetFrames=48000',
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

VGMultiSourceAudioTrackSinkSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGMultiSourceAudioTrackSinkSmokeReport.fromMap(
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

  group('VGMultiSourceAudioTrackSinkSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGMultiSourceAudioTrackSinkSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.status, equals('pass'));
        expect(report.marker, equals(_kPassMarker));
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.failureReason, isEmpty);
        expect(report.lastError, isEmpty);
        expect(report.details, contains('seekAcceptedFrame=16800'));
        expect(report.detachCancellationProven, isFalse);

        // Physically asserted lanes (19 lanes)
        expect(report.formatProbeOk, isTrue);
        expect(report.audioTrackInitOk, isTrue);
        expect(report.prerollOk, isTrue);
        expect(report.playbackHeadMonotonicOk, isTrue);
        expect(report.playbackHeadAdvancedOk, isTrue);
        expect(report.playbackHeadBoundedOk, isTrue);
        expect(report.sinkWriteAccountingOk, isTrue);
        expect(report.seekEpochAccountingOk, isTrue);
        expect(report.jointDispatchGateOk, isTrue);
        expect(report.jointTailFlushOk, isTrue);
        expect(report.twoTrackContributionOk, isTrue);
        expect(report.referenceMixChecksumOk, isTrue);
        expect(report.nativeDrainChecksumMatchesSinkOk, isTrue);
        expect(report.trackFrameAxisLockstepOk, isTrue);
        expect(report.mixedOutputFrameAccountingOk, isTrue);
        expect(report.zeroNativeSteadyStateAllocationOk, isTrue);
        expect(report.ownerThreadOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.canonical, isTrue);

        // Conditional / telemetry lanes (3 lanes)
        expect(report.cancellationPollingLiveOk, isTrue);
        expect(report.audioTimestampAvailable, isTrue);
        expect(report.audioTimestampValidOk, isTrue);

        // Metrics (31 metrics)
        expect(report.cancellationPollCount, equals(48));
        expect(report.sampleRate, equals(48000));
        expect(report.channelCount, equals(2));
        expect(report.commonBudgetFrames, equals(48000));
        expect(report.framesTruncatedBeyondBudget, equals(0));
        expect(report.totalFramesExtracted, equals(48000));
        expect(report.playbackHeadFinal, equals(48000));
        expect(report.framesWrittenTotal, equals(48000));
        expect(report.framesReadFromRingTotal, equals(48000));
        expect(report.partialWriteCount, equals(0));
        expect(report.zeroWriteCount, equals(0));
        expect(report.getUnderrunCount, equals(0));
        expect(report.bufferSizeInFrames, equals(4096));
        expect(report.bufferCapacityInFrames, equals(8192));
        expect(report.maxHeadLagFrames, equals(512));
        expect(report.finalHeadLagFrames, equals(0));
        expect(report.prerollFrames, equals(512));
        expect(report.prerollEpochsSatisfied, equals(2));
        expect(report.seekAcceptedFrame, equals(16800));
        expect(report.generatorReanchorCount, equals(1));
        expect(report.track1NonZeroSampleCount, equals(96000));
        expect(report.totalFramesAcceptedTrack0, equals(48000));
        expect(report.totalFramesAcceptedTrack1, equals(48000));
        expect(report.totalOutputFramesDrained, equals(48000));
        expect(report.dispatchCount, equals(188));
        expect(report.audioTimestampAttemptCount, equals(12));
        expect(report.audioTimestampSuccessCount, equals(10));
        expect(report.nativeOutputDrainChecksumHex, equals(_kChecksumHex));
        expect(report.kotlinReferenceMixChecksumHex, equals(_kChecksumHex));
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

        final roundTrip = VGMultiSourceAudioTrackSinkSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGMultiSourceAudioTrackSinkSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'status': 'reference_mix_checksum_mismatch',
          'marker': _kFailMarker,
          'failureReason': 'reference_mix_checksum_mismatch',
          'lastError': 'reference_mix_checksum_mismatch',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.status, equals('reference_mix_checksum_mismatch'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('reference_mix_checksum_mismatch'));
      expect(report.lastError, equals('reference_mix_checksum_mismatch'));
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
        final report = VGMultiSourceAudioTrackSinkSmokeReport.fromMap(invalid);
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
        expect(report.totalFramesAcceptedTrack0, equals(0));
        expect(report.totalFramesAcceptedTrack1, equals(0));
        expect(report.totalOutputFramesDrained, equals(0));
        expect(report.getUnderrunCount, equals(-1));
        expect(report.finalHeadLagFrames, equals(-1));
        expect(report.seekAcceptedFrame, equals(-1));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGMultiSourceAudioTrackSinkSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'marker=$_kPassMarker;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'formatProbeOk=true;'
            'audioTrackInitOk=true;'
            'prerollOk=true;'
            'playbackHeadMonotonicOk=true;'
            'playbackHeadAdvancedOk=true;'
            'playbackHeadBoundedOk=true;'
            'sinkWriteAccountingOk=true;'
            'seekEpochAccountingOk=true;'
            'jointDispatchGateOk=true;'
            'jointTailFlushOk=true;'
            'twoTrackContributionOk=true;'
            'referenceMixChecksumOk=true;'
            'nativeDrainChecksumMatchesSinkOk=true;'
            'trackFrameAxisLockstepOk=true;'
            'mixedOutputFrameAccountingOk=true;'
            'zeroNativeSteadyStateAllocationOk=true;'
            'ownerThreadOk=true;'
            'lifecycleOk=true;'
            'canonical=true;'
            'cancellationPollingLiveOk=true;'
            'audioTimestampAvailable=true;'
            'audioTimestampValidOk=true;'
            'cancellationPollCount=48;'
            'sampleRate=48000;'
            'channelCount=2;'
            'commonBudgetFrames=48000;'
            'framesTruncatedBeyondBudget=0;'
            'totalFramesExtracted=48000;'
            'playbackHeadFinal=48000;'
            'framesWrittenTotal=48000;'
            'framesReadFromRingTotal=48000;'
            'partialWriteCount=0;'
            'zeroWriteCount=0;'
            'getUnderrunCount=0;'
            'bufferSizeInFrames=4096;'
            'bufferCapacityInFrames=8192;'
            'maxHeadLagFrames=512;'
            'finalHeadLagFrames=0;'
            'prerollFrames=512;'
            'prerollEpochsSatisfied=2;'
            'seekAcceptedFrame=16800;'
            'generatorReanchorCount=1;'
            'track1NonZeroSampleCount=96000;'
            'totalFramesAcceptedTrack0=48000;'
            'totalFramesAcceptedTrack1=48000;'
            'totalOutputFramesDrained=48000;'
            'dispatchCount=188;'
            'audioTimestampAttemptCount=12;'
            'audioTimestampSuccessCount=10;'
            'nativeOutputDrainChecksumHex=$_kChecksumHex;'
            'kotlinReferenceMixChecksumHex=$_kChecksumHex;'
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
      expect(reportFromRaw.playbackHeadMonotonicOk, isTrue);
      expect(reportFromRaw.playbackHeadAdvancedOk, isTrue);
      expect(reportFromRaw.playbackHeadBoundedOk, isTrue);
      expect(reportFromRaw.sinkWriteAccountingOk, isTrue);
      expect(reportFromRaw.seekEpochAccountingOk, isTrue);
      expect(reportFromRaw.jointDispatchGateOk, isTrue);
      expect(reportFromRaw.jointTailFlushOk, isTrue);
      expect(reportFromRaw.twoTrackContributionOk, isTrue);
      expect(reportFromRaw.referenceMixChecksumOk, isTrue);
      expect(reportFromRaw.nativeDrainChecksumMatchesSinkOk, isTrue);
      expect(reportFromRaw.trackFrameAxisLockstepOk, isTrue);
      expect(reportFromRaw.mixedOutputFrameAccountingOk, isTrue);
      expect(reportFromRaw.zeroNativeSteadyStateAllocationOk, isTrue);
      expect(reportFromRaw.ownerThreadOk, isTrue);
      expect(reportFromRaw.lifecycleOk, isTrue);
      expect(reportFromRaw.canonical, isTrue);
      expect(reportFromRaw.cancellationPollingLiveOk, isTrue);
      expect(reportFromRaw.audioTimestampAvailable, isTrue);
      expect(reportFromRaw.audioTimestampValidOk, isTrue);
      expect(reportFromRaw.sampleRate, equals(48000));
      expect(reportFromRaw.channelCount, equals(2));
      expect(reportFromRaw.playbackHeadFinal, equals(48000));
      expect(reportFromRaw.framesWrittenTotal, equals(48000));
      expect(reportFromRaw.framesReadFromRingTotal, equals(48000));
      expect(reportFromRaw.finalHeadLagFrames, equals(0));
      expect(reportFromRaw.prerollFrames, equals(512));
      expect(reportFromRaw.totalFramesAcceptedTrack0, equals(48000));
      expect(reportFromRaw.totalFramesAcceptedTrack1, equals(48000));
      expect(reportFromRaw.totalOutputFramesDrained, equals(48000));
      expect(reportFromRaw.dispatchCount, equals(188));
      expect(reportFromRaw.nativeOutputDrainChecksumHex, equals(_kChecksumHex));
      expect(
        reportFromRaw.kotlinReferenceMixChecksumHex,
        equals(_kChecksumHex),
      );
      expect(reportFromRaw.kotlinSinkChecksumHex, equals(_kChecksumHex));
      expect(reportFromRaw.nativeLastStatus, equals('drained'));
      expect(reportFromRaw.checksumsMatch, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in lanes and metrics', () {
      final report = VGMultiSourceAudioTrackSinkSmokeReport.fromMap({
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
      final report = VGMultiSourceAudioTrackSinkSmokeReport.fromMap({
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
    test('checksumsMatch verifies 3-way non-empty identity and lanes ok', () {
      final report = _createSampleReport();
      expect(report.checksumsMatch, isTrue);

      expect(
        _createSampleReport({
          'kotlinReferenceMixChecksumHex': '',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'nativeOutputDrainChecksumHex': '',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({'kotlinSinkChecksumHex': ''}).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'kotlinReferenceMixChecksumHex': 'mismatch',
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
        _createSampleReport({'referenceMixChecksumOk': false}).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'nativeDrainChecksumMatchesSinkOk': false,
        }).checksumsMatch,
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
          'playbackHeadBoundedOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'sinkWriteAccountingOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'seekEpochAccountingOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'jointDispatchGateOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'jointTailFlushOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'twoTrackContributionOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'referenceMixChecksumOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'nativeDrainChecksumMatchesSinkOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'trackFrameAxisLockstepOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'mixedOutputFrameAccountingOk': false,
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
        _createSampleReport({'commonBudgetFrames': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'totalFramesExtracted': 0}).allNativeLanesPass,
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
          'framesWrittenTotal': 48000,
          'framesReadFromRingTotal': 47000,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'framesReadFromRingTotal': 48000,
          'totalOutputFramesDrained': 47000,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'prerollFrames': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'prerollEpochsSatisfied': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'seekAcceptedFrame': -1}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'generatorReanchorCount': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'track1NonZeroSampleCount': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalFramesAcceptedTrack0': 0,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalFramesAcceptedTrack1': 0,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalFramesAcceptedTrack0': 48000,
          'totalFramesAcceptedTrack1': 47000,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'totalOutputFramesDrained': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalOutputFramesDrained': 47000,
          'totalFramesAcceptedTrack0': 48000,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'dispatchCount': 0}).allNativeLanesPass,
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
      expect(a.toString(), contains('VGMultiSourceAudioTrackSinkSmokeReport('));
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
        {'playbackHeadMonotonicOk': false},
        {'playbackHeadAdvancedOk': false},
        {'playbackHeadBoundedOk': false},
        {'sinkWriteAccountingOk': false},
        {'seekEpochAccountingOk': false},
        {'jointDispatchGateOk': false},
        {'jointTailFlushOk': false},
        {'twoTrackContributionOk': false},
        {'referenceMixChecksumOk': false},
        {'nativeDrainChecksumMatchesSinkOk': false},
        {'trackFrameAxisLockstepOk': false},
        {'mixedOutputFrameAccountingOk': false},
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
        {'commonBudgetFrames': 44100},
        {'framesTruncatedBeyondBudget': 100},
        {'totalFramesExtracted': 999},
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
        {'prerollEpochsSatisfied': 5},
        {'seekAcceptedFrame': 1024},
        {'generatorReanchorCount': 5},
        {'track1NonZeroSampleCount': 999},
        {'totalFramesAcceptedTrack0': 999},
        {'totalFramesAcceptedTrack1': 999},
        {'totalOutputFramesDrained': 999},
        {'dispatchCount': 100},
        {'audioTimestampAttemptCount': 99},
        {'audioTimestampSuccessCount': 99},
        {'nativeOutputDrainChecksumHex': 'diff'},
        {'kotlinReferenceMixChecksumHex': 'diff'},
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

  group('MethodChannel wrapper: runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke', () {
    test(
      'invokes runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke with correct default args on default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGMultiSourceAudioTrackSinkSmokeReport.runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke(
              sourcePath: '/path/to/test/clip_B.mov',
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke'),
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
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('passes custom parameters and deadlineMs correctly', () async {
      MethodCall? capturedCall;
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGMultiSourceAudioTrackSinkSmokeReport.runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke(
            sourcePath: '/custom/path.mov',
            durationSec: 1.5,
            seekTargetSec: 0.5,
            volume: 0.8,
            sourceRingCapacityFrames: 16384,
            outputRingCapacityFrames: 8192,
            maxFramesPerMix: 512,
            timeout: const Duration(seconds: 40),
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.arguments,
        equals(<String, Object?>{
          'sourcePath': '/custom/path.mov',
          'durationSec': 1.5,
          'seekTargetSec': 0.5,
          'volume': 0.8,
          'sourceRingCapacityFrames': 16384,
          'outputRingCapacityFrames': 8192,
          'maxFramesPerMix': 512,
          'deadlineMs': 40000,
        }),
      );
      expect(report.pass, isTrue);
    });

    test('handles TimeoutException gracefully with fallback report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return _createSampleRawMap();
      });

      final report =
          await VGMultiSourceAudioTrackSinkSmokeReport.runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke(
            sourcePath: '/path/to/test.mov',
            timeout: const Duration(milliseconds: 10),
          );

      expect(report.pass, isFalse);
      expect(report.status, equals('fail'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('timeout'));
      expect(report.lastError, contains('timeout'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('handles PlatformException gracefully with fallback report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw PlatformException(
          code: 'P4_MULTI_SOURCE_AUDIO_TRACK_SINK_SMOKE_BUSY',
          message: 'diagnostic already running',
        );
      });

      final report =
          await VGMultiSourceAudioTrackSinkSmokeReport.runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke(
            sourcePath: '/path/to/test.mov',
          );

      expect(report.pass, isFalse);
      expect(report.status, equals('fail'));
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_MULTI_SOURCE_AUDIO_TRACK_SINK_SMOKE_BUSY',
        ),
      );
      expect(report.details, equals('diagnostic already running'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('handles generic exception gracefully with fallback report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw Exception('Native crash simulated');
      });

      final report =
          await VGMultiSourceAudioTrackSinkSmokeReport.runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke(
            sourcePath: '/path/to/test.mov',
          );

      expect(report.pass, isFalse);
      expect(report.status, equals('fail'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, contains('Native crash simulated'));
      expect(report.allNativeLanesPass, isFalse);
    });
  });
}
