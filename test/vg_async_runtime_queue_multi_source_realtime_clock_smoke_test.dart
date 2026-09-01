// vg_async_runtime_queue_multi_source_realtime_clock_smoke_test.dart
// vanguard_media_engine -
// P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-REALTIME-CLOCK: Android
// True-DAG Phase 4 two-source node-owned async runtime queue worker-owned
// steady_clock realtime pacing Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'kotlin_owned_audiotrack_sink_on_async_runtime_queue_multi_source_realtime_wall_clock_pacing_proof_only_real_decoder_plus_synthetic_track_to_async_runtime_queue_scheduler_output_ring_to_muted_audiotrack_mode_stream_sink_write_accounting_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_synthetic_pcm_track_kotlin_owned_write_non_blocking_only_playback_head_and_audio_timestamp_telemetry_only_two_routed_tracks_unit_gain_lockstep_ingest_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_no_audible_output_no_speaker_route_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_dead_object_recovery_no_aaudio_no_opensl_no_oboe_no_latency_glitch_avsync_claim_no_zero_underrun_claim_no_realtime_priority_claim_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes';

const _kNativeProofBoundary =
    'diagnostic_async_runtime_queue_multi_source_realtime_clock_native_worker_proof_only_real_decoder_plus_synthetic_track_node_owned_source_rings_to_graph_scheduler_audio_mix_bus_to_output_ring_worker_owned_std_chrono_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_on_any_control_command_two_routed_tracks_unit_gain_lockstep_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_native_audio_sink_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_audible_output_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_zero_underrun_claim_no_realtime_priority_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_SMOKE_FAIL';
const _kEnvelopePassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_DYNAMIC_GAIN_ENVELOPE_SMOKE_PASS';
const _kNonZeroGainPassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_NONZERO_GAIN_SINK_PHYSICAL_SMOKE_PASS';
const _kFocusNoisyPassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_NOISY_EVENT_HANDOFF_PHYSICAL_SMOKE_PASS';
const _kFocusDuckRestorePassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_DUCK_RESTORE_PHYSICAL_SMOKE_PASS';

const _kFocusDuckRestoreProofBoundary =
    'kotlin_owned_audiotrack_sink_on_async_runtime_queue_multi_source_focus_duck_restore_response_proof_only_real_decoder_plus_synthetic_track_to_async_runtime_queue_scheduler_output_ring_to_nonzero_gain_audiotrack_mode_stream_sink_write_accounting_sink_side_focus_duck_restore_setvolume_only_base_gain_0_5_duck_gain_0_1_restore_gain_0_5_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_synthetic_pcm_track_kotlin_owned_write_non_blocking_only_playback_head_and_audio_timestamp_telemetry_only_two_routed_tracks_lockstep_ingest_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_no_acoustic_audibility_claim_no_speaker_verification_no_loudness_snr_claim_no_pause_resume_restart_no_os_focus_arbitration_correctness_no_route_change_recovery_no_dead_object_recovery_no_aaudio_no_opensl_no_oboe_no_latency_glitch_xrun_underrun_freedom_claim_no_realtime_priority_claim_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes';
const _kTrack0Hex = '00000000abcdef12';
const _kTrack1Hex = '00000000abcdef34';
const _kMixHex = '00000000abcdef56';

const _kLaneKeys = <String>[
  'formatProbeOk',
  'decoderEosReachedOk',
  'realtimeWorkerClockOwnershipOk',
  'noCallerSuppliedNativeTimeOk',
  'noOwnerThreadDispatchOk',
  'controlCommandSerializationOk',
  'multiSourceRealDecoderIngestOk',
  'trackFrameAxisLockstepOk',
  'twoTrackContributionOk',
  'referenceMixChecksumOk',
  'checksumIdentityOk',
  'frameAccountingOk',
  'sinkWriteAccountingOk',
  'providerPoisoningOk',
  'audioTrackInitOk',
  'mutedOutputOk',
  'playbackHeadTelemetryOk',
  'realtimeNativeElapsedOk',
  'realtimeBacklogBoundOk',
  'seekEpochReanchorOk',
  'seekSinkEpochResetOk',
  'syntheticGeneratorReanchorOk',
  'workerJoinOnDestroyOk',
  'idempotentDestroyOk',
  'canonicalProofBoundaryOk',
  'ownerThreadAffinityOk',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{for (final lane in _kLaneKeys) lane: true};

  // Geometry mirrors the frozen X4 run at 48kHz stereo:
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
    'generatorReanchorCount': 1,
    'nativeRealtimeElapsedMs': 1004,
    'nativeTimingF0': 8192,
    'nativeTimingF1': 56192,
    'maxRenderCursorBacklogUs': 41250,
    'backlogSampleCount': 290,
    'clockDriftSampleCount': 290,
    'workerNoFramesDueWaits': 352,
    'workerStarvedWaits': 4,
    'backpressureCountTelemetry': 3,
    'totalFramesExtracted': 96000,
    'totalFramesAcceptedTrack0': 83968,
    'totalFramesAcceptedTrack1': 83968,
    'totalFramesRendered': 83968,
    'totalFramesPushed': 83968,
    'totalOutputFramesRead': 83968,
    'framesReadFromRing': 83968,
    'framesWrittenToSink': 83968,
    'residualFramesAtEnd': 0,
    'framesDiscardedInSinkAtSeek': 1024,
    'playbackHeadDeltaTelemetryOnly': 12800,
    'underrunDeltaTelemetryOnly': 0,
    'commandsEnqueued': 2,
    'commandsProcessed': 2,
    'commandErrors': 0,
    'dispatchCount': 328,
    'silenceCount': 0,
    'providerTrack0ZeroFilledFrames': 0,
    'providerTrack1ZeroFilledFrames': 0,
    'providerTrack0UnderrunEvents': 0,
    'providerTrack1UnderrunEvents': 0,
    'providerTrack0ForwardSkipFrames': 0,
    'providerTrack1ForwardSkipFrames': 0,
    'providerTrack0RewindRejects': 0,
    'providerTrack1RewindRejects': 0,
    'workerThreadDistinct': true,
    'ownerDispatchCalls': 0,
    'kotlinTrack0AcceptedChecksumHex': _kTrack0Hex,
    'nativeAcceptedChecksumTrack0Hex': _kTrack0Hex,
    'kotlinTrack1AcceptedChecksumHex': _kTrack1Hex,
    'nativeAcceptedChecksumTrack1Hex': _kTrack1Hex,
    'kotlinReferenceMixChecksumHex': _kMixHex,
    'nativeOutputReadChecksumHex': _kMixHex,
    'kotlinSinkWriteChecksumHex': _kMixHex,
    'track0NonZeroSampleCount': 160000,
    'track1NonZeroSampleCount': 167000,
    'nativeLastStatus': 'ok',
    // X5 telemetry at its exact X4 defaults (no envelope applied).
    'envelopeProofEnabled': false,
    'envelopeApplied': false,
    'envelopeEvaluations': 0,
    'minEffectiveGain': 0.0,
    'maxEffectiveGain': 0.0,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kNativeProofBoundary,
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kNativeProofBoundary,
    'failureReason': '',
    'details':
        'preStartFillFrames=4608|seekAcceptedFrame=57600|'
        'generatorReanchorCount=1|nativeRealtimeElapsedMs=1004|'
        'maxRenderCursorBacklogUs=41250',
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

// X5 dynamic-gain-envelope pass payload: the X4 sample map with the
// envelope marker, envelope-mode metrics, and the dynamicGainEnvelopeOk
// lane. Envelope keys must live INSIDE the lanes/metrics maps because the
// typed getters read only those maps.
Map<String, Object?> _createEnvelopeSampleRawMap([
  Map<String, Object?>? overrides,
]) {
  final result = _createSampleRawMap();
  result['marker'] = _kEnvelopePassMarker;
  (result['raw'] as Map<String, String>)['marker'] = _kEnvelopePassMarker;
  final metrics = result['metrics'] as Map<String, Object?>;
  metrics['envelopeProofEnabled'] = true;
  metrics['envelopeApplied'] = true;
  metrics['envelopeEvaluations'] = 167936;
  metrics['minEffectiveGain'] = 0.25;
  metrics['maxEffectiveGain'] = 1.0;
  final lanes = result['lanes'] as Map<String, Object?>;
  lanes['dynamicGainEnvelopeOk'] = true;
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

// X6 non-zero-gain sink proof pass payload: the X4 sample map with X6
// marker, mode flag, and gain facts. The mutedOutputOk lane is omitted
// (false in X6 mode); nonZeroGainSinkGatesHeld replaces it in the verdict.
Map<String, Object?> _createNonZeroGainSampleRawMap([
  Map<String, Object?>? overrides,
]) {
  final result = _createSampleRawMap();
  result['marker'] = _kNonZeroGainPassMarker;
  (result['raw'] as Map<String, String>)['marker'] = _kNonZeroGainPassMarker;
  final lanes = result['lanes'] as Map<String, Object?>;
  lanes['mutedOutputOk'] = false;
  lanes['nonZeroGainSinkGatesHeld'] = true;
  final metrics = result['metrics'] as Map<String, Object?>;
  metrics['nonZeroGainSinkProofEnabled'] = true;
  metrics['audioTrackGain'] = 0.5;
  metrics['audioTrackNonZeroGainSetOk'] = true;
  metrics['nonZeroGainSinkGatesHeld'] = true;
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

  group(
    'VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport fromMap/toMap',
    () {
      test('pass report parses all lanes, metrics, and fields cleanly', () {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              _createSampleRawMap(),
            );

        expect(report.pass, isTrue);
        expect(report.status, equals('pass'));
        expect(report.marker, equals(_kPassMarker));
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.nativeProofBoundary, equals(_kNativeProofBoundary));
        expect(report.nativeProofBoundaryOk, isTrue);
        expect(report.failureReason, isEmpty);
        expect(report.lastError, isEmpty);
        expect(report.details, contains('generatorReanchorCount=1'));

        // Lanes (26 lanes).
        expect(report.formatProbeOk, isTrue);
        expect(report.decoderEosReachedOk, isTrue);
        expect(report.realtimeWorkerClockOwnershipOk, isTrue);
        expect(report.noCallerSuppliedNativeTimeOk, isTrue);
        expect(report.noOwnerThreadDispatchOk, isTrue);
        expect(report.controlCommandSerializationOk, isTrue);
        expect(report.multiSourceRealDecoderIngestOk, isTrue);
        expect(report.trackFrameAxisLockstepOk, isTrue);
        expect(report.twoTrackContributionOk, isTrue);
        expect(report.referenceMixChecksumOk, isTrue);
        expect(report.checksumIdentityOk, isTrue);
        expect(report.frameAccountingOk, isTrue);
        expect(report.sinkWriteAccountingOk, isTrue);
        expect(report.providerPoisoningOk, isTrue);
        expect(report.audioTrackInitOk, isTrue);
        expect(report.mutedOutputOk, isTrue);
        expect(report.playbackHeadTelemetryOk, isTrue);
        expect(report.realtimeNativeElapsedOk, isTrue);
        expect(report.realtimeBacklogBoundOk, isTrue);
        expect(report.seekEpochReanchorOk, isTrue);
        expect(report.seekSinkEpochResetOk, isTrue);
        expect(report.syntheticGeneratorReanchorOk, isTrue);
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
        expect(report.generatorReanchorCount, equals(1));
        expect(report.nativeRealtimeElapsedMs, equals(1004));
        expect(report.nativeTimingF0, equals(8192));
        expect(report.nativeTimingF1, equals(56192));
        expect(report.maxRenderCursorBacklogUs, equals(41250));
        expect(report.backlogSampleCount, equals(290));
        expect(report.workerNoFramesDueWaits, equals(352));
        expect(report.backpressureCountTelemetry, equals(3));
        expect(report.totalFramesExtracted, equals(96000));
        expect(report.totalFramesAcceptedTrack0, equals(83968));
        expect(report.totalFramesAcceptedTrack1, equals(83968));
        expect(report.totalFramesRendered, equals(83968));
        expect(report.totalFramesPushed, equals(83968));
        expect(report.totalOutputFramesRead, equals(83968));
        expect(report.framesReadFromRing, equals(83968));
        expect(report.framesWrittenToSink, equals(83968));
        expect(report.residualFramesAtEnd, equals(0));
        expect(report.framesDiscardedInSinkAtSeek, equals(1024));
        expect(report.playbackHeadDeltaTelemetryOnly, equals(12800));
        expect(report.underrunDeltaTelemetryOnly, equals(0));
        expect(report.commandsEnqueued, equals(2));
        expect(report.commandsProcessed, equals(2));
        expect(report.commandErrors, equals(0));
        expect(report.silenceCount, equals(0));
        expect(report.providerTrack0ZeroFilledFrames, equals(0));
        expect(report.providerTrack1ZeroFilledFrames, equals(0));
        expect(report.providerTrack0UnderrunEvents, equals(0));
        expect(report.providerTrack1UnderrunEvents, equals(0));
        expect(report.providerTrack0ForwardSkipFrames, equals(0));
        expect(report.providerTrack1ForwardSkipFrames, equals(0));
        expect(report.providerTrack0RewindRejects, equals(0));
        expect(report.providerTrack1RewindRejects, equals(0));
        expect(report.workerThreadDistinct, isTrue);
        expect(report.ownerDispatchCalls, equals(0));
        expect(report.kotlinTrack0AcceptedChecksumHex, equals(_kTrack0Hex));
        expect(report.nativeAcceptedChecksumTrack0Hex, equals(_kTrack0Hex));
        expect(report.kotlinTrack1AcceptedChecksumHex, equals(_kTrack1Hex));
        expect(report.nativeAcceptedChecksumTrack1Hex, equals(_kTrack1Hex));
        expect(report.kotlinReferenceMixChecksumHex, equals(_kMixHex));
        expect(report.nativeOutputReadChecksumHex, equals(_kMixHex));
        expect(report.kotlinSinkWriteChecksumHex, equals(_kMixHex));

        // Getters.
        expect(report.trackChecksumsMatch, isTrue);
        expect(report.mixChecksumsMatch, isTrue);
        expect(report.checksumsMatch, isTrue);
        expect(report.providerCountersClean, isTrue);
        expect(report.sinkAccountingBalanced, isTrue);
        expect(report.realtimeGatesHeld, isTrue);
        expect(report.allNativeLanesPass, isTrue);

        // Serialization round-trip.
        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['marker'], equals(_kPassMarker));
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(
          serialized['nativeProofBoundary'],
          equals(_kNativeProofBoundary),
        );
        final roundTrip =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              serialized,
            );
        expect(roundTrip, equals(report));
      });

      test('fail report parses failure flags and lastError correctly', () {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              _createSampleRawMap({
                'pass': false,
                'status': 'seek_track_frame_axis_divergence',
                'marker': _kFailMarker,
                'failureReason': 'seek_track_frame_axis_divergence',
                'lastError': 'seek_track_frame_axis_divergence',
              }),
            );

        expect(report.pass, isFalse);
        expect(report.status, equals('seek_track_frame_axis_divergence'));
        expect(report.marker, equals(_kFailMarker));
        expect(
          report.failureReason,
          equals('seek_track_frame_axis_divergence'),
        );
        expect(report.lastError, equals('seek_track_frame_axis_divergence'));
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
          final report =
              VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
                invalid,
              );
          expect(report.pass, isFalse);
          expect(report.hasCanonicalProofBoundary, isFalse);
          expect(report.nativeProofBoundaryOk, isFalse);
          expect(report.proofBoundary, isEmpty);
          expect(report.status, equals('fail'));
          expect(report.marker, equals(_kFailMarker));
          expect(report.lastError, equals('native_result_not_a_map'));
          expect(report.allNativeLanesPass, isFalse);
          expect(report.totalFramesAcceptedTrack0, equals(0));
          expect(report.totalFramesAcceptedTrack1, equals(0));
          expect(report.framesWrittenToSink, equals(0));
          expect(report.residualFramesAtEnd, equals(-1));
          expect(report.nativeRealtimeElapsedMs, equals(-1));
          expect(report.maxRenderCursorBacklogUs, equals(-1));
          expect(report.generatorReanchorCount, equals(-1));
          expect(report.ownerDispatchCalls, equals(-1));
        }
      });
    },
  );

  group('allNativeLanesPass verification contract', () {
    test('requires the Kotlin driver proof boundary to match', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'proofBoundary': 'shortened_boundary'}),
          );
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires the native TU proof boundary to match', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({
              'nativeProofBoundary': 'shortened_native_boundary',
            }),
          );
      expect(report.nativeProofBoundaryOk, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires marker to match pass marker constant', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'marker': _kFailMarker}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires every lane boolean to be true', () {
      for (final lane in _kLaneKeys) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
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
      final notDistinct =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'workerThreadDistinct': false}),
          );
      expect(notDistinct.allNativeLanesPass, isFalse);

      final ownerDispatched =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'ownerDispatchCalls': 1}),
          );
      expect(ownerDispatched.allNativeLanesPass, isFalse);
    });

    test('requires exactly two serialized commands with zero errors', () {
      final unbalanced =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'commandsProcessed': 1}),
          );
      expect(unbalanced.allNativeLanesPass, isFalse);

      final errored =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'commandErrors': 1}),
          );
      expect(errored.allNativeLanesPass, isFalse);
    });

    test('requires the native realtime elapsed gate window', () {
      final tooFast =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'nativeRealtimeElapsedMs': 512}),
          );
      expect(tooFast.realtimeGatesHeld, isFalse);
      expect(tooFast.allNativeLanesPass, isFalse);

      final tooSlow =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'nativeRealtimeElapsedMs': 1500}),
          );
      expect(tooSlow.realtimeGatesHeld, isFalse);
      expect(tooSlow.allNativeLanesPass, isFalse);
    });

    test('requires the native render-cursor backlog bound', () {
      final overBound =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'maxRenderCursorBacklogUs': 250000}),
          );
      expect(overBound.realtimeGatesHeld, isFalse);
      expect(overBound.allNativeLanesPass, isFalse);

      final noSamples =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'backlogSampleCount': 0}),
          );
      expect(noSamples.realtimeGatesHeld, isFalse);
      expect(noSamples.allNativeLanesPass, isFalse);
    });

    test('does not require backpressure (normal telemetry in X4)', () {
      final noBackpressure =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'backpressureCountTelemetry': 0}),
          );
      expect(noBackpressure.allNativeLanesPass, isTrue);
    });

    test('requires the lockstep pre-start source fill quota', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'preStartFillFrames': 2048}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires both per-track input checksum identities', () {
      final track0Mismatch =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({
              'nativeAcceptedChecksumTrack0Hex': '0000000011111111',
            }),
          );
      expect(track0Mismatch.trackChecksumsMatch, isFalse);
      expect(track0Mismatch.allNativeLanesPass, isFalse);

      final track1Mismatch =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({
              'nativeAcceptedChecksumTrack1Hex': '0000000022222222',
            }),
          );
      expect(track1Mismatch.trackChecksumsMatch, isFalse);
      expect(track1Mismatch.allNativeLanesPass, isFalse);
    });

    test('requires the mixed output identity through the sink', () {
      final readMismatch =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({
              'nativeOutputReadChecksumHex': '0000000033333333',
            }),
          );
      expect(readMismatch.mixChecksumsMatch, isFalse);
      expect(readMismatch.allNativeLanesPass, isFalse);

      final sinkMismatch =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({
              'kotlinSinkWriteChecksumHex': '0000000044444444',
            }),
          );
      expect(sinkMismatch.mixChecksumsMatch, isFalse);
      expect(sinkMismatch.allNativeLanesPass, isFalse);

      final empty =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'kotlinSinkWriteChecksumHex': ''}),
          );
      expect(empty.mixChecksumsMatch, isFalse);
      expect(empty.allNativeLanesPass, isFalse);
    });

    test('requires lockstep frame accounting on both tracks', () {
      final track1Short =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'totalFramesAcceptedTrack1': 83000}),
          );
      expect(track1Short.allNativeLanesPass, isFalse);

      final readShort =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'totalOutputFramesRead': 83000}),
          );
      expect(readShort.allNativeLanesPass, isFalse);
    });

    test('requires the lossless sink write accounting identity', () {
      final shortWrite =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'framesWrittenToSink': 83712}),
          );
      expect(shortWrite.sinkAccountingBalanced, isFalse);
      expect(shortWrite.allNativeLanesPass, isFalse);

      final residual =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'residualFramesAtEnd': 256}),
          );
      expect(residual.sinkAccountingBalanced, isFalse);
      expect(residual.allNativeLanesPass, isFalse);
    });

    test('requires all per-track provider poisoning counters to be zero', () {
      for (final key in const [
        'providerTrack0ZeroFilledFrames',
        'providerTrack1ZeroFilledFrames',
        'providerTrack0UnderrunEvents',
        'providerTrack1UnderrunEvents',
        'providerTrack0ForwardSkipFrames',
        'providerTrack1ForwardSkipFrames',
        'providerTrack0RewindRejects',
        'providerTrack1RewindRejects',
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              _createSampleRawMap({key: 1}),
            );
        expect(report.providerCountersClean, isFalse, reason: key);
        expect(report.allNativeLanesPass, isFalse, reason: key);
      }
    });

    test('requires zero coordinator silence windows in the identity', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'silenceCount': 1}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires the seek target to equal the pre-seek budget frame', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'seekTargetFrame': 57344}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires exactly one synthetic generator re-anchor', () {
      final none =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'generatorReanchorCount': 0}),
          );
      expect(none.allNativeLanesPass, isFalse);

      final twice =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'generatorReanchorCount': 2}),
          );
      expect(twice.allNativeLanesPass, isFalse);
    });

    test('requires telemetry-only playback head progression post-seek', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'playbackHeadDeltaTelemetryOnly': 0}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });
  });

  group('X5 dynamic gain envelope mode', () {
    test('default X4 pass report keeps the exact no-envelope defaults', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap(),
          );
      expect(report.envelopeProofEnabled, isFalse);
      expect(report.envelopeApplied, isFalse);
      expect(report.envelopeEvaluations, equals(0));
      expect(report.minEffectiveGain, equals(0.0));
      expect(report.maxEffectiveGain, equals(0.0));
      expect(report.dynamicGainEnvelopeGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X4 run reporting envelope application fails the default gate', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'envelopeApplied': true}),
          );
      expect(report.dynamicGainEnvelopeGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('envelope pass report parses telemetry and passes all lanes', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createEnvelopeSampleRawMap(),
          );
      expect(report.marker, equals(_kEnvelopePassMarker));
      expect(report.envelopeProofEnabled, isTrue);
      expect(report.envelopeApplied, isTrue);
      expect(report.envelopeEvaluations, equals(167936));
      expect(report.minEffectiveGain, equals(0.25));
      expect(report.maxEffectiveGain, equals(1.0));
      expect(report.dynamicGainEnvelopeGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('envelope run must carry the envelope pass marker', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createEnvelopeSampleRawMap({'marker': _kPassMarker}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('envelope run requires envelopeApplied with evaluations > 0', () {
      final notApplied =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createEnvelopeSampleRawMap({'envelopeApplied': false}),
          );
      expect(notApplied.dynamicGainEnvelopeGatesHeld, isFalse);
      expect(notApplied.allNativeLanesPass, isFalse);

      final noEvaluations =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createEnvelopeSampleRawMap({'envelopeEvaluations': 0}),
          );
      expect(noEvaluations.dynamicGainEnvelopeGatesHeld, isFalse);
      expect(noEvaluations.allNativeLanesPass, isFalse);
    });

    test('envelope run requires min < max effective gain within [0,1]', () {
      final flatGain =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createEnvelopeSampleRawMap({'minEffectiveGain': 1.0}),
          );
      expect(flatGain.dynamicGainEnvelopeGatesHeld, isFalse);
      expect(flatGain.allNativeLanesPass, isFalse);

      final overUnity =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createEnvelopeSampleRawMap({'maxEffectiveGain': 1.5}),
          );
      expect(overUnity.dynamicGainEnvelopeGatesHeld, isFalse);
      expect(overUnity.allNativeLanesPass, isFalse);

      final negativeMin =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createEnvelopeSampleRawMap({'minEffectiveGain': -0.1}),
          );
      expect(negativeMin.dynamicGainEnvelopeGatesHeld, isFalse);
      expect(negativeMin.allNativeLanesPass, isFalse);
    });

    test('envelope run requires the dynamicGainEnvelopeOk lane', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createEnvelopeSampleRawMap({'dynamicGainEnvelopeOk': false}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('envelope mode sends envelopeProofEnabled=true only', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createEnvelopeSampleRawMap();
      });

      final report =
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: '/tmp/clip_B.mov',
            envelopeProofEnabled: true,
          );

      expect(capturedArgs?['envelopeProofEnabled'], isTrue);
      expect(report.pass, isTrue);
      expect(report.envelopeProofEnabled, isTrue);
      expect(report.allNativeLanesPass, isTrue);
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
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: '/tmp/clip_B.mov',
          );

      expect(
        capturedMethod,
        equals('runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke'),
      );
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
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
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
          code: 'P4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_SMOKE_BUSY',
          message: 'runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke: busy',
        );
      });

      final report =
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: '/tmp/x.mov',
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:'
          'P4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_SMOKE_BUSY',
        ),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('missing plugin produces unsupported fail-shaped report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw MissingPluginException('no implementation');
      });

      final report =
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
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
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
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
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: '/tmp/x.mov',
            channel: const _ThrowingMethodChannel('test_throwing'),
          );

      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('exception:'));
      expect(report.lastError, contains('simulated non-platform exception'));
      expect(report.allNativeLanesPass, isFalse);
    });
  });

  group('X6 non-zero-gain sink proof mode', () {
    test(
      'default X4 pass report has nonZeroGainSinkProofEnabled=false, gain=0.0, gatesHeld=true',
      () {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              _createSampleRawMap(),
            );
        expect(report.nonZeroGainSinkProofEnabled, isFalse);
        expect(report.audioTrackGain, equals(0.0));
        expect(report.audioTrackNonZeroGainSetOk, isFalse);
        expect(report.nonZeroGainSinkGatesHeld, isTrue);
        expect(report.mutedOutputOk, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('X6 pass report passes all gates with non-zero gain set OK', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createNonZeroGainSampleRawMap(),
          );
      expect(report.marker, equals(_kNonZeroGainPassMarker));
      expect(report.nonZeroGainSinkProofEnabled, isTrue);
      expect(report.audioTrackGain, equals(0.5));
      expect(report.audioTrackNonZeroGainSetOk, isTrue);
      expect(report.nonZeroGainSinkGatesHeld, isTrue);
      expect(report.mutedOutputOk, isFalse);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X6 run must carry the non-zero-gain pass marker', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createNonZeroGainSampleRawMap({'marker': _kPassMarker}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X6 rejects missing gain set OK', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createNonZeroGainSampleRawMap({
              'audioTrackNonZeroGainSetOk': false,
            }),
          );
      expect(report.nonZeroGainSinkGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X6 rejects gain == 0.0', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createNonZeroGainSampleRawMap({'audioTrackGain': 0.0}),
          );
      expect(report.nonZeroGainSinkGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X6 rejects gain > 1.0', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createNonZeroGainSampleRawMap({'audioTrackGain': 1.5}),
          );
      expect(report.nonZeroGainSinkGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X6 requires the nonZeroGainSinkGatesHeld lane', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createNonZeroGainSampleRawMap({'nonZeroGainSinkGatesHeld': false}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X6 mode sends nonZeroGainSinkProofEnabled=true only', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createNonZeroGainSampleRawMap();
      });

      final report =
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: '/tmp/clip_B.mov',
            nonZeroGainSinkProofEnabled: true,
          );

      expect(capturedArgs?['nonZeroGainSinkProofEnabled'], isTrue);
      expect(capturedArgs?.containsKey('envelopeProofEnabled'), isFalse);
      expect(report.pass, isTrue);
      expect(report.nonZeroGainSinkProofEnabled, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('default X4 run does NOT send nonZeroGainSinkProofEnabled', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createSampleRawMap();
      });

      await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
        sourcePath: '/tmp/clip_B.mov',
      );

      expect(capturedArgs?.containsKey('nonZeroGainSinkProofEnabled'), isFalse);
    });
  });

  group('X7 focus/noisy event-plane proof mode', () {
    // X7 pass sample map: X4 base with X7 marker, mode flag, and event-plane
    // lane/metric additions from coordinator extraLanes/extraMetrics.
    Map<String, Object?> createX7SampleRawMap([
      Map<String, Object?>? overrides,
    ]) {
      final result = _createSampleRawMap();
      result['marker'] = _kFocusNoisyPassMarker;
      (result['raw'] as Map<String, String>)['marker'] = _kFocusNoisyPassMarker;
      final lanes = result['lanes'] as Map<String, Object?>;
      lanes['audioFocusRequestGrantedOk'] = true;
      lanes['audioFocusAbandonedOk'] = true;
      lanes['noisyReceiverRegisteredOk'] = true;
      lanes['noisyReceiverUnregisteredOk'] = true;
      lanes['focusNoisyOwnerThreadDrainOk'] = true;
      lanes['focusNoisyEventHandoffGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      metrics['focusNoisyEventHandoffProofEnabled'] = true;
      metrics['focusNoisySyntheticEventsPosted'] = 2;
      metrics['focusNoisyEventsEnqueued'] = 2;
      metrics['focusNoisyEventsDropped'] = 0;
      metrics['focusNoisyEventsDrained'] = 2;
      if (overrides != null) {
        for (final entry in overrides.entries) {
          if (lanes.containsKey(entry.key)) lanes[entry.key] = entry.value;
          if (metrics.containsKey(entry.key)) metrics[entry.key] = entry.value;
          result[entry.key] = entry.value;
        }
      }
      return result;
    }

    test('default X4 pass report has focusNoisyEventHandoffProofEnabled=false '
        'and gate vacuously true', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap(),
          );
      expect(report.focusNoisyEventHandoffProofEnabled, isFalse);
      expect(report.audioFocusRequestGrantedOk, isFalse);
      expect(report.audioFocusAbandonedOk, isFalse);
      expect(report.noisyReceiverRegisteredOk, isFalse);
      expect(report.noisyReceiverUnregisteredOk, isFalse);
      expect(report.focusNoisySyntheticEventsPosted, equals(0));
      expect(report.focusNoisyEventsEnqueued, equals(0));
      expect(report.focusNoisyEventsDrained, equals(0));
      expect(report.focusNoisyEventsDropped, equals(0));
      expect(report.focusNoisyOwnerThreadDrainOk, isFalse);
      // Gate is vacuously true when X7 disabled.
      expect(report.focusNoisyEventHandoffGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X7 pass report passes all gates with focus/receiver/event OK', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX7SampleRawMap(),
          );
      expect(report.marker, equals(_kFocusNoisyPassMarker));
      expect(report.focusNoisyEventHandoffProofEnabled, isTrue);
      expect(report.audioFocusRequestGrantedOk, isTrue);
      expect(report.audioFocusAbandonedOk, isTrue);
      expect(report.noisyReceiverRegisteredOk, isTrue);
      expect(report.noisyReceiverUnregisteredOk, isTrue);
      expect(report.focusNoisySyntheticEventsPosted, equals(2));
      expect(report.focusNoisyEventsEnqueued, equals(2));
      expect(report.focusNoisyEventsDrained, equals(2));
      expect(report.focusNoisyEventsDropped, equals(0));
      expect(report.focusNoisyOwnerThreadDrainOk, isTrue);
      expect(report.focusNoisyEventHandoffGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X7 run must carry the focus/noisy pass marker', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX7SampleRawMap({'marker': _kPassMarker}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X7 requires audioFocusRequestGrantedOk', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX7SampleRawMap({'audioFocusRequestGrantedOk': false}),
          );
      expect(report.focusNoisyEventHandoffGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X7 requires audioFocusAbandonedOk', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX7SampleRawMap({'audioFocusAbandonedOk': false}),
          );
      expect(report.focusNoisyEventHandoffGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X7 requires noisyReceiverRegisteredOk', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX7SampleRawMap({'noisyReceiverRegisteredOk': false}),
          );
      expect(report.focusNoisyEventHandoffGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X7 requires noisyReceiverUnregisteredOk', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX7SampleRawMap({'noisyReceiverUnregisteredOk': false}),
          );
      expect(report.focusNoisyEventHandoffGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X7 requires focusNoisyOwnerThreadDrainOk', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX7SampleRawMap({'focusNoisyOwnerThreadDrainOk': false}),
          );
      expect(report.focusNoisyEventHandoffGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X7 requires focusNoisyEventHandoffGatesHeld native lane', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX7SampleRawMap({'focusNoisyEventHandoffGatesHeld': false}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X7 dropped events cause gate failure (enqueued != drained)', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX7SampleRawMap({
              'focusNoisyEventsDropped': 1,
              'focusNoisyEventsEnqueued': 3,
              'focusNoisyEventsDrained': 2,
            }),
          );
      // dropped > 0 violates the gate
      expect(report.focusNoisyEventsDropped, equals(1));
      expect(report.focusNoisyEventHandoffGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X7 gate fails when drained != enqueued', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX7SampleRawMap({
              'focusNoisyEventsEnqueued': 2,
              'focusNoisyEventsDrained': 1,
            }),
          );
      expect(report.focusNoisyEventHandoffGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X7 gate fails when no synthetic events posted', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX7SampleRawMap({
              'focusNoisySyntheticEventsPosted': 0,
              'focusNoisyEventsEnqueued': 0,
              'focusNoisyEventsDrained': 0,
            }),
          );
      expect(report.focusNoisyEventHandoffGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X7 mode sends focusNoisyEventHandoffProofEnabled=true', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return createX7SampleRawMap();
      });

      final report =
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: '/tmp/clip_B.mov',
            focusNoisyEventHandoffProofEnabled: true,
          );

      expect(capturedArgs?['focusNoisyEventHandoffProofEnabled'], isTrue);
      expect(capturedArgs?.containsKey('envelopeProofEnabled'), isFalse);
      expect(capturedArgs?.containsKey('nonZeroGainSinkProofEnabled'), isFalse);
      expect(report.pass, isTrue);
      expect(report.focusNoisyEventHandoffProofEnabled, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test(
      'default X4 run does NOT send focusNoisyEventHandoffProofEnabled',
      () async {
        Map<String, Object?>? capturedArgs;

        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedArgs = (call.arguments as Map).cast<String, Object?>();
          return _createSampleRawMap();
        });

        await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
          sourcePath: '/tmp/clip_B.mov',
        );

        expect(
          capturedArgs?.containsKey('focusNoisyEventHandoffProofEnabled'),
          isFalse,
        );
      },
    );
  });

  group('X8 focus-duck/restore response proof mode', () {
    // X8 pass sample map: X4 base with the X8 marker, the X8 mode-specific
    // proof boundary, the implied X7 focus/noisy lanes/metrics, the implied
    // non-zero 0.5 base gain facts, and the X8 duck/restore lanes/metrics.
    Map<String, Object?> createX8SampleRawMap([
      Map<String, Object?>? overrides,
    ]) {
      final result = _createSampleRawMap();
      result['marker'] = _kFocusDuckRestorePassMarker;
      result['proofBoundary'] = _kFocusDuckRestoreProofBoundary;
      final rawStrings = result['raw'] as Map<String, String>;
      rawStrings['marker'] = _kFocusDuckRestorePassMarker;
      rawStrings['proofBoundary'] = _kFocusDuckRestoreProofBoundary;
      final lanes = result['lanes'] as Map<String, Object?>;
      // X8 implies the non-zero base gain: the muted lane is honestly false.
      lanes['mutedOutputOk'] = false;
      // Implied X7 focus/noisy lanes.
      lanes['audioFocusRequestGrantedOk'] = true;
      lanes['audioFocusAbandonedOk'] = true;
      lanes['noisyReceiverRegisteredOk'] = true;
      lanes['noisyReceiverUnregisteredOk'] = true;
      lanes['focusNoisyOwnerThreadDrainOk'] = true;
      lanes['focusNoisyEventHandoffGatesHeld'] = true;
      // X8 coordinator lanes.
      lanes['focusListenerRegisteredOk'] = true;
      lanes['focusDuckRestoreGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      // Implied X7 metrics.
      metrics['focusNoisyEventHandoffProofEnabled'] = true;
      metrics['focusNoisySyntheticEventsPosted'] = 2;
      metrics['focusNoisyEventsEnqueued'] = 2;
      metrics['focusNoisyEventsDropped'] = 0;
      metrics['focusNoisyEventsDrained'] = 2;
      // Implied non-zero 0.5 base gain facts (nonZeroGainSinkProofEnabled
      // itself stays false: X8 is its own mode).
      metrics['audioTrackGain'] = 0.5;
      metrics['audioTrackNonZeroGainSetOk'] = true;
      // X8 duck/restore metrics.
      metrics['focusDuckRestoreProofEnabled'] = true;
      metrics['syntheticDuckPosted'] = 1;
      metrics['syntheticGainPosted'] = 1;
      metrics['duckAppliedCount'] = 1;
      metrics['restoreAppliedCount'] = 1;
      metrics['duckSetVolumeOk'] = true;
      metrics['restoreSetVolumeOk'] = true;
      metrics['duckDrainSeq'] = 3;
      metrics['restoreDrainSeq'] = 57;
      metrics['baseVolume'] = 0.5;
      metrics['duckedVolume'] = 0.1;
      metrics['restoredVolume'] = 0.5;
      metrics['finalVolume'] = 0.5;
      metrics['duckEventsEnqueued'] = 1;
      metrics['gainEventsEnqueued'] = 1;
      metrics['duckEventsDrained'] = 1;
      metrics['gainEventsDrained'] = 1;
      metrics['focusEventsDropped'] = 0;
      metrics['realFocusChangeCallbackCount'] = 0;
      if (overrides != null) {
        for (final entry in overrides.entries) {
          if (lanes.containsKey(entry.key)) lanes[entry.key] = entry.value;
          if (metrics.containsKey(entry.key)) metrics[entry.key] = entry.value;
          result[entry.key] = entry.value;
        }
      }
      return result;
    }

    test('default X4 pass report has focusDuckRestoreProofEnabled=false '
        'and gate vacuously true', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap(),
          );
      expect(report.focusDuckRestoreProofEnabled, isFalse);
      expect(report.focusListenerRegisteredOk, isFalse);
      expect(report.syntheticDuckPosted, equals(0));
      expect(report.syntheticGainPosted, equals(0));
      expect(report.duckAppliedCount, equals(-1));
      expect(report.restoreAppliedCount, equals(-1));
      expect(report.duckSetVolumeOk, isFalse);
      expect(report.restoreSetVolumeOk, isFalse);
      expect(report.duckDrainSeq, equals(-1));
      expect(report.restoreDrainSeq, equals(-1));
      expect(report.focusEventsDropped, equals(0));
      // Gate is vacuously true when X8 disabled.
      expect(report.focusDuckRestoreGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X7-only pass report keeps X8 defaults and still passes', () {
      final result = _createSampleRawMap();
      result['marker'] = _kFocusNoisyPassMarker;
      (result['raw'] as Map<String, String>)['marker'] = _kFocusNoisyPassMarker;
      final lanes = result['lanes'] as Map<String, Object?>;
      lanes['audioFocusRequestGrantedOk'] = true;
      lanes['audioFocusAbandonedOk'] = true;
      lanes['noisyReceiverRegisteredOk'] = true;
      lanes['noisyReceiverUnregisteredOk'] = true;
      lanes['focusNoisyOwnerThreadDrainOk'] = true;
      lanes['focusNoisyEventHandoffGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      metrics['focusNoisyEventHandoffProofEnabled'] = true;
      metrics['focusNoisySyntheticEventsPosted'] = 2;
      metrics['focusNoisyEventsEnqueued'] = 2;
      metrics['focusNoisyEventsDropped'] = 0;
      metrics['focusNoisyEventsDrained'] = 2;
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            result,
          );
      expect(report.focusDuckRestoreProofEnabled, isFalse);
      expect(report.focusDuckRestoreGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X8 pass report passes all gates with duck and restore applied', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX8SampleRawMap(),
          );
      expect(report.marker, equals(_kFocusDuckRestorePassMarker));
      expect(report.focusDuckRestoreProofEnabled, isTrue);
      expect(report.focusListenerRegisteredOk, isTrue);
      expect(report.syntheticDuckPosted, equals(1));
      expect(report.syntheticGainPosted, equals(1));
      expect(report.duckAppliedCount, equals(1));
      expect(report.restoreAppliedCount, equals(1));
      expect(report.duckSetVolumeOk, isTrue);
      expect(report.restoreSetVolumeOk, isTrue);
      expect(report.duckDrainSeq, lessThan(report.restoreDrainSeq));
      expect(report.baseVolume, equals(0.5));
      expect(report.duckedVolume, equals(0.1));
      expect(report.restoredVolume, equals(0.5));
      expect(report.finalVolume, equals(0.5));
      expect(report.focusEventsDropped, equals(0));
      expect(report.focusDuckRestoreGatesHeld, isTrue);
      // Implied X7 and non-zero-gain gates hold too.
      expect(report.focusNoisyEventHandoffGatesHeld, isTrue);
      expect(report.nonZeroGainSinkGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X8 run must carry the focus-duck/restore pass marker', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX8SampleRawMap({'marker': _kFocusNoisyPassMarker}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X8 must not carry the old muted/no-focus proof boundary', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX8SampleRawMap({'proofBoundary': _kCanonicalProofBoundary}),
          );
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X8 requires focusListenerRegisteredOk', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX8SampleRawMap({'focusListenerRegisteredOk': false}),
          );
      expect(report.focusDuckRestoreGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X8 requires exactly one applied duck with setVolume SUCCESS', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX8SampleRawMap({
              'duckAppliedCount': 0,
              'duckSetVolumeOk': false,
            }),
          );
      expect(report.focusDuckRestoreGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X8 requires exactly one applied restore with setVolume SUCCESS', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX8SampleRawMap({
              'restoreAppliedCount': 0,
              'restoreSetVolumeOk': false,
            }),
          );
      expect(report.focusDuckRestoreGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X8 requires the focusDuckRestoreGatesHeld native lane', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX8SampleRawMap({'focusDuckRestoreGatesHeld': false}),
          );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X8 gate fails when the restore did not follow the duck '
        '(duckDrainSeq >= restoreDrainSeq)', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX8SampleRawMap({'duckDrainSeq': 57, 'restoreDrainSeq': 3}),
          );
      expect(report.focusDuckRestoreGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X8 gate fails on dropped events', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX8SampleRawMap({'focusEventsDropped': 1}),
          );
      expect(report.focusEventsDropped, equals(1));
      expect(report.focusDuckRestoreGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X8 gate fails on per-tag enqueued/drained mismatch', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX8SampleRawMap({'gainEventsDrained': 0}),
          );
      expect(report.focusDuckRestoreGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X8 gate fails when the synthetic gain was never posted', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX8SampleRawMap({
              'syntheticGainPosted': 0,
              'gainEventsEnqueued': 0,
              'gainEventsDrained': 0,
              'restoreAppliedCount': 0,
            }),
          );
      expect(report.focusDuckRestoreGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X8 gate fails when the final volume is not the restored base', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX8SampleRawMap({'finalVolume': 0.1}),
          );
      expect(report.focusDuckRestoreGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X8 mode sends focusDuckRestoreProofEnabled=true only', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return createX8SampleRawMap();
      });

      final report =
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: '/tmp/clip_B.mov',
            focusDuckRestoreProofEnabled: true,
          );

      expect(capturedArgs?['focusDuckRestoreProofEnabled'], isTrue);
      // The implied X7 flag is derived natively; the Dart wrapper never
      // sends it (nor any other mode flag) for an X8 run.
      expect(
        capturedArgs?.containsKey('focusNoisyEventHandoffProofEnabled'),
        isFalse,
      );
      expect(capturedArgs?.containsKey('envelopeProofEnabled'), isFalse);
      expect(capturedArgs?.containsKey('nonZeroGainSinkProofEnabled'), isFalse);
      expect(report.pass, isTrue);
      expect(report.focusDuckRestoreProofEnabled, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('default X4 run does NOT send focusDuckRestoreProofEnabled', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createSampleRawMap();
      });

      await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
        sourcePath: '/tmp/clip_B.mov',
      );

      expect(
        capturedArgs?.containsKey('focusDuckRestoreProofEnabled'),
        isFalse,
      );
    });
  });

  group('Equality, hashCode, and toString', () {
    test('equal reports compare equal and have identical hashCode', () {
      final reportA =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap(),
          );
      final reportB =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap(),
          );

      expect(reportA, equals(reportB));
      expect(reportA.hashCode, equals(reportB.hashCode));
      expect(
        reportA.toString(),
        contains('VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport('),
      );
    });

    test('different reports do not compare equal', () {
      final reportA =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'nativeRealtimeElapsedMs': 1004}),
          );
      final reportB =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap({'nativeRealtimeElapsedMs': 1100}),
          );

      expect(reportA, isNot(equals(reportB)));
    });
  });
}
