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
const _kFocusLossPauseResumePassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_LOSS_PAUSE_RESUME_PHYSICAL_SMOKE_PASS';
const _kPermanentFocusLossPassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_PERMANENT_FOCUS_LOSS_PHYSICAL_SMOKE_PASS';
const _kRouteChangeEventHandoffPassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_ROUTE_CHANGE_EVENT_HANDOFF_PHYSICAL_SMOKE_PASS';
const _kDeadObjectRecoveryPassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_DEAD_OBJECT_RECOVERY_PHYSICAL_SMOKE_PASS';
const _kTimestampStabilizationPassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_SMOKE_PASS';
const _kTimestampStabilizationFailMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_SMOKE_FAIL';
const _kAudibleSpeakerPlaybackPassMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIBLE_SPEAKER_PLAYBACK_PHYSICAL_SMOKE_PASS';
const _kAudibleSpeakerPlaybackFailMarker =
    'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIBLE_SPEAKER_PLAYBACK_PHYSICAL_SMOKE_FAIL';

const _kAudibleSpeakerPlaybackProofBoundary =
    'kotlin_owned_audiotrack_sink_on_async_runtime_queue_multi_source_audible_speaker_playback_diagnostic_proof_only_sm_a566b_manual_acoustic_observation_lane_only_real_decoder_plus_synthetic_track_to_async_runtime_queue_scheduler_output_ring_to_nonzero_gain_audiotrack_mode_stream_sink_write_accounting_base_gain_0_5_owner_thread_routed_device_sampled_after_each_epoch_play_type_builtin_speaker_required_os_routing_report_only_no_automatic_acoustic_audibility_claim_no_loudness_snr_claim_no_speaker_verification_beyond_routed_device_type_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_dead_object_recovery_no_timestamp_stabilization_gate_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_synthetic_pcm_track_kotlin_owned_write_non_blocking_only_playback_head_and_audio_timestamp_telemetry_only_two_routed_tracks_unit_gain_lockstep_ingest_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_no_aaudio_no_opensl_no_oboe_no_latency_glitch_xrun_underrun_freedom_claim_no_avsync_claim_no_drift_claim_no_zero_underrun_claim_no_realtime_priority_claim_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes';

const _kDeadObjectRecoveryProofBoundary =
    'kotlin_owned_audiotrack_sink_on_async_runtime_queue_multi_source_dead_object_recovery_response_proof_only_real_decoder_plus_synthetic_track_to_async_runtime_queue_scheduler_output_ring_to_nonzero_gain_audiotrack_mode_stream_sink_write_accounting_sink_side_synthetic_dead_object_detection_and_recreation_only_base_gain_0_5_synthetic_dead_object_injected_once_old_track_released_new_track_initialized_and_resumed_no_real_os_dead_object_forcing_claim_no_acoustic_audibility_claim_no_speaker_verification_no_loudness_snr_claim_no_seamless_hardware_hot_swap_claim_no_os_route_arbitration_correctness_no_production_restart_policy_no_pause_resume_sla_no_aaudio_no_opensl_no_oboe_no_latency_glitch_xrun_underrun_freedom_claim_no_avsync_claim_no_realtime_priority_claim_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes';

const _kTimestampStabilizationProofBoundary =
    'kotlin_owned_audiotrack_sink_on_async_runtime_queue_multi_source_audiotrack_timestamp_stabilization_diagnostic_proof_only_real_decoder_plus_synthetic_track_to_async_runtime_queue_scheduler_output_ring_to_muted_audiotrack_mode_stream_sink_write_accounting_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_synthetic_pcm_track_kotlin_owned_write_non_blocking_only_playback_head_telemetry_only_audio_timestamp_poll_cadence_and_per_epoch_frame_monotonicity_diagnostic_gate_only_one_poll_per_output_pass_after_write_returns_no_poll_inside_write_retry_loop_warmup_after_epoch_play_only_bounded_by_existing_deadline_per_epoch_baseline_reset_on_seek_flush_no_cross_epoch_comparison_unsigned_32bit_frame_position_one_positive_wrap_tolerated_equal_frame_position_allowed_strict_backward_only_fails_nanotime_monotonicity_telemetry_only_no_pacing_feedback_no_dispatch_feedback_no_write_size_feedback_no_checksum_effect_two_routed_tracks_unit_gain_lockstep_ingest_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_no_audible_output_no_speaker_route_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_dead_object_recovery_no_presentation_clock_claim_no_latency_claim_no_avsync_claim_no_drift_claim_no_hal_timestamp_accuracy_claim_no_aaudio_no_opensl_no_oboe_no_zero_underrun_claim_no_realtime_priority_claim_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes';

const _kTimestampStabilizationDeadObjectRecoveryProofBoundary =
    'kotlin_owned_audiotrack_sink_on_async_runtime_queue_multi_source_audiotrack_timestamp_stabilization_with_dead_object_recovery_response_diagnostic_proof_only_real_decoder_plus_synthetic_track_to_async_runtime_queue_scheduler_output_ring_to_nonzero_gain_audiotrack_mode_stream_sink_write_accounting_sink_side_synthetic_dead_object_detection_and_recreation_only_base_gain_0_5_synthetic_dead_object_injected_once_old_track_released_new_track_initialized_and_resumed_no_real_os_dead_object_forcing_claim_playback_head_telemetry_only_audio_timestamp_poll_cadence_and_per_epoch_frame_monotonicity_diagnostic_gate_only_one_poll_per_output_pass_after_write_returns_no_poll_inside_write_retry_loop_warmup_after_epoch_play_only_bounded_by_existing_deadline_per_epoch_baseline_reset_on_seek_flush_and_after_synthetic_dead_object_recreation_no_cross_epoch_comparison_unsigned_32bit_frame_position_one_positive_wrap_tolerated_equal_frame_position_allowed_strict_backward_only_fails_nanotime_monotonicity_telemetry_only_no_pacing_feedback_no_dispatch_feedback_no_write_size_feedback_no_checksum_effect_no_acoustic_audibility_claim_no_speaker_verification_no_loudness_snr_claim_no_seamless_hardware_hot_swap_claim_no_os_route_arbitration_correctness_no_production_restart_policy_no_pause_resume_sla_no_presentation_clock_claim_no_latency_claim_no_avsync_claim_no_drift_claim_no_hal_timestamp_accuracy_claim_no_aaudio_no_opensl_no_oboe_no_latency_glitch_xrun_underrun_freedom_claim_no_realtime_priority_claim_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes';

const _kFocusLossPauseResumeProofBoundary =
    'kotlin_owned_audiotrack_sink_on_async_runtime_queue_multi_source_focus_loss_pause_resume_response_proof_only_real_decoder_plus_synthetic_track_to_async_runtime_queue_scheduler_output_ring_to_nonzero_gain_audiotrack_mode_stream_sink_write_accounting_sink_side_audiotrack_playstate_pause_play_only_base_gain_0_5_transient_loss_pause_focus_gain_play_becoming_noisy_terminal_pause_no_flush_no_stop_no_auto_resume_before_release_no_transport_pause_no_presentation_pause_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_synthetic_pcm_track_kotlin_owned_write_non_blocking_only_playback_head_and_audio_timestamp_telemetry_only_two_routed_tracks_lockstep_ingest_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_no_acoustic_audibility_claim_no_speaker_verification_no_loudness_snr_claim_no_pause_resume_sla_no_production_restart_policy_no_os_focus_arbitration_correctness_no_route_change_recovery_no_dead_object_recovery_no_aaudio_no_opensl_no_oboe_no_latency_glitch_xrun_underrun_freedom_claim_no_avsync_claim_no_realtime_priority_claim_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes';

const _kPermanentFocusLossProofBoundary =
    'kotlin_owned_audiotrack_sink_on_async_runtime_queue_multi_source_focus_loss_permanent_stop_response_proof_only_real_decoder_plus_synthetic_track_to_async_runtime_queue_scheduler_output_ring_to_nonzero_gain_audiotrack_mode_stream_sink_write_accounting_sink_side_audiotrack_playstate_pause_only_base_gain_0_5_permanent_loss_terminal_pause_synthetic_focus_gain_attempt_rejected_no_play_no_auto_resume_no_flush_no_stop_no_release_recreate_no_transport_pause_no_presentation_pause_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_synthetic_pcm_track_kotlin_owned_write_non_blocking_only_playback_head_and_audio_timestamp_telemetry_only_two_routed_tracks_lockstep_ingest_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_no_acoustic_audibility_claim_no_speaker_verification_no_loudness_snr_claim_no_pause_resume_sla_no_production_restart_policy_no_os_focus_arbitration_correctness_no_route_change_recovery_no_dead_object_recovery_no_aaudio_no_opensl_no_oboe_no_latency_glitch_xrun_underrun_freedom_claim_no_avsync_claim_no_realtime_priority_claim_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes';

const _kRouteChangeEventHandoffProofBoundary =
    'kotlin_owned_audiotrack_sink_on_async_runtime_queue_multi_source_route_change_event_handoff_response_proof_only_real_decoder_plus_synthetic_track_to_async_runtime_queue_scheduler_output_ring_to_nonzero_gain_audiotrack_mode_stream_sink_write_accounting_sink_side_audiotrack_playstate_pause_only_base_gain_0_5_route_changed_pre_start_synthetic_drain_route_disconnect_terminal_synthetic_pause_fail_closed_no_play_no_auto_resume_no_route_recreation_no_stream_reanchor_no_dead_object_recovery_routing_listener_registered_and_unregistered_exactly_once_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_synthetic_pcm_track_kotlin_owned_write_non_blocking_only_playback_head_and_audio_timestamp_telemetry_only_two_routed_tracks_lockstep_ingest_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_no_acoustic_audibility_claim_no_speaker_verification_no_os_route_arbitration_correctness_no_production_restart_policy_no_pause_resume_sla_no_seamless_route_recreation_no_hot_swap_no_aaudio_no_opensl_no_oboe_no_latency_glitch_xrun_underrun_freedom_claim_no_avsync_claim_no_realtime_priority_claim_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes';

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

// X14 audible speaker playback proof pass payload: the X4 sample map with
// X14 marker, X14 proof boundary, mode flag, 0.5 gain, and routed-device
// facts (TYPE_BUILTIN_SPEAKER = 2). The mutedOutputOk lane is omitted
// (false in X14 mode); audibleSpeakerPlaybackGatesHeld and nonZeroGainSinkGatesHeld
// replace it in the verdict.
Map<String, Object?> _createAudibleSpeakerSampleRawMap([
  Map<String, Object?>? overrides,
]) {
  final result = _createSampleRawMap();
  result['marker'] = _kAudibleSpeakerPlaybackPassMarker;
  result['proofBoundary'] = _kAudibleSpeakerPlaybackProofBoundary;
  final rawStrings = result['raw'] as Map<String, String>;
  rawStrings['marker'] = _kAudibleSpeakerPlaybackPassMarker;
  rawStrings['proofBoundary'] = _kAudibleSpeakerPlaybackProofBoundary;
  final lanes = result['lanes'] as Map<String, Object?>;
  lanes['mutedOutputOk'] = false;
  lanes['nonZeroGainSinkGatesHeld'] = true;
  lanes['audibleSpeakerPlaybackGatesHeld'] = true;
  final metrics = result['metrics'] as Map<String, Object?>;
  metrics['audioTrackGain'] = 0.5;
  metrics['audioTrackNonZeroGainSetOk'] = true;
  metrics['nonZeroGainSinkGatesHeld'] = true;
  metrics['audibleSpeakerPlaybackProofEnabled'] = true;
  metrics['audibleSpeakerRouteSampleCount'] = 2;
  metrics['audibleSpeakerRouteSampleOk'] = true;
  metrics['audibleSpeakerRouteType'] = 2;
  metrics['audibleSpeakerBuiltInSpeakerRouteOk'] = true;
  metrics['audibleSpeakerPlaybackGatesHeld'] = true;
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

  group('X9 focus-loss pause/resume response proof mode', () {
    // X9 pass sample map: X4 base with the X9 marker, the X9 mode-specific
    // proof boundary, the implied X7 focus/noisy lanes/metrics, the implied
    // non-zero 0.5 base gain facts, and the X9 pause/resume lanes/metrics.
    // X8 duck/restore facts stay at their defaults: X9 never enables X8.
    Map<String, Object?> createX9SampleRawMap([
      Map<String, Object?>? overrides,
    ]) {
      final result = _createSampleRawMap();
      result['marker'] = _kFocusLossPauseResumePassMarker;
      result['proofBoundary'] = _kFocusLossPauseResumeProofBoundary;
      final rawStrings = result['raw'] as Map<String, String>;
      rawStrings['marker'] = _kFocusLossPauseResumePassMarker;
      rawStrings['proofBoundary'] = _kFocusLossPauseResumeProofBoundary;
      final lanes = result['lanes'] as Map<String, Object?>;
      // X9 implies the non-zero base gain: the muted lane is honestly false.
      lanes['mutedOutputOk'] = false;
      // Implied X7 focus/noisy lanes.
      lanes['audioFocusRequestGrantedOk'] = true;
      lanes['audioFocusAbandonedOk'] = true;
      lanes['noisyReceiverRegisteredOk'] = true;
      lanes['noisyReceiverUnregisteredOk'] = true;
      lanes['focusNoisyOwnerThreadDrainOk'] = true;
      lanes['focusNoisyEventHandoffGatesHeld'] = true;
      // X9 coordinator lane.
      lanes['focusLossPauseResumeGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      // Implied X7 metrics.
      metrics['focusNoisyEventHandoffProofEnabled'] = true;
      metrics['focusNoisySyntheticEventsPosted'] = 2;
      metrics['focusNoisyEventsEnqueued'] = 2;
      metrics['focusNoisyEventsDropped'] = 0;
      metrics['focusNoisyEventsDrained'] = 2;
      // Implied non-zero 0.5 base gain facts (nonZeroGainSinkProofEnabled
      // and focusDuckRestoreProofEnabled stay false: X9 is its own mode).
      metrics['audioTrackGain'] = 0.5;
      metrics['audioTrackNonZeroGainSetOk'] = true;
      metrics['focusDuckRestoreProofEnabled'] = false;
      // X9 driver metrics (sink-side playstate telemetry only).
      metrics['focusLossPauseResumeProofEnabled'] = true;
      metrics['transientLossAppliedCount'] = 1;
      metrics['focusGainAppliedCount'] = 1;
      metrics['becomingNoisyAppliedCount'] = 1;
      metrics['focusLossPauseOk'] = true;
      metrics['focusGainResumeOk'] = true;
      metrics['becomingNoisyPauseOk'] = true;
      metrics['transientPauseApplySeq'] = 0;
      metrics['focusGainResumeApplySeq'] = 1;
      metrics['noisyPauseApplySeq'] = 2;
      metrics['playStateAfterTransientPause'] = 2;
      metrics['playStateAfterFocusGainResume'] = 3;
      metrics['playStateAfterNoisyPause'] = 2;
      metrics['playStateAtRelease'] = 2;
      metrics['terminalPlayStatePausedBeforeReleaseOk'] = true;
      // X9 coordinator metrics.
      metrics['syntheticTransientLossPosted'] = 1;
      metrics['syntheticFocusGainPosted'] = 1;
      metrics['syntheticBecomingNoisyPosted'] = 1;
      metrics['transientLossEventsEnqueued'] = 1;
      metrics['focusGainEventsEnqueued'] = 1;
      metrics['becomingNoisyEventsEnqueued'] = 1;
      metrics['transientLossEventsDrained'] = 1;
      metrics['focusGainEventsDrained'] = 1;
      metrics['becomingNoisyEventsDrained'] = 1;
      metrics['focusLossPauseResumeEventsDropped'] = 0;
      metrics['focusLossRealFocusChangeCallbackCount'] = 0;
      if (overrides != null) {
        for (final entry in overrides.entries) {
          if (lanes.containsKey(entry.key)) lanes[entry.key] = entry.value;
          if (metrics.containsKey(entry.key)) metrics[entry.key] = entry.value;
          result[entry.key] = entry.value;
        }
      }
      return result;
    }

    test('default X4 pass report has focusLossPauseResumeProofEnabled=false '
        'and gate vacuously true', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap(),
          );
      expect(report.focusLossPauseResumeProofEnabled, isFalse);
      expect(report.focusLossPauseOk, isFalse);
      expect(report.focusGainResumeOk, isFalse);
      expect(report.becomingNoisyPauseOk, isFalse);
      expect(report.terminalPlayStatePausedBeforeReleaseOk, isFalse);
      expect(report.syntheticTransientLossPosted, equals(0));
      expect(report.syntheticFocusGainPosted, equals(0));
      expect(report.syntheticBecomingNoisyPosted, equals(0));
      expect(report.transientLossAppliedCount, equals(-1));
      expect(report.focusGainAppliedCount, equals(-1));
      expect(report.becomingNoisyAppliedCount, equals(-1));
      expect(report.transientPauseApplySeq, equals(-1));
      expect(report.focusGainResumeApplySeq, equals(-1));
      expect(report.noisyPauseApplySeq, equals(-1));
      expect(report.focusLossPauseResumeEventsDropped, equals(0));
      // Gate is vacuously true when X9 disabled.
      expect(report.focusLossPauseResumeGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X8 pass report keeps X9 defaults and still passes', () {
      final result = _createSampleRawMap();
      result['marker'] = _kFocusDuckRestorePassMarker;
      result['proofBoundary'] = _kFocusDuckRestoreProofBoundary;
      final rawStrings = result['raw'] as Map<String, String>;
      rawStrings['marker'] = _kFocusDuckRestorePassMarker;
      rawStrings['proofBoundary'] = _kFocusDuckRestoreProofBoundary;
      final lanes = result['lanes'] as Map<String, Object?>;
      lanes['mutedOutputOk'] = false;
      lanes['audioFocusRequestGrantedOk'] = true;
      lanes['audioFocusAbandonedOk'] = true;
      lanes['noisyReceiverRegisteredOk'] = true;
      lanes['noisyReceiverUnregisteredOk'] = true;
      lanes['focusNoisyOwnerThreadDrainOk'] = true;
      lanes['focusNoisyEventHandoffGatesHeld'] = true;
      lanes['focusListenerRegisteredOk'] = true;
      lanes['focusDuckRestoreGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      metrics['focusNoisyEventHandoffProofEnabled'] = true;
      metrics['focusNoisySyntheticEventsPosted'] = 2;
      metrics['focusNoisyEventsEnqueued'] = 2;
      metrics['focusNoisyEventsDropped'] = 0;
      metrics['focusNoisyEventsDrained'] = 2;
      metrics['audioTrackGain'] = 0.5;
      metrics['audioTrackNonZeroGainSetOk'] = true;
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
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            result,
          );
      expect(report.focusDuckRestoreProofEnabled, isTrue);
      expect(report.focusLossPauseResumeProofEnabled, isFalse);
      expect(report.focusLossPauseResumeGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X9 pass report passes all gates with pause, resume, and terminal '
        'noisy pause applied', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap(),
          );
      expect(report.marker, equals(_kFocusLossPauseResumePassMarker));
      expect(report.proofBoundary, equals(_kFocusLossPauseResumeProofBoundary));
      expect(report.focusLossPauseResumeProofEnabled, isTrue);
      // X9 never enables X8.
      expect(report.focusDuckRestoreProofEnabled, isFalse);
      expect(report.focusDuckRestoreGatesHeld, isTrue);
      expect(report.focusLossPauseOk, isTrue);
      expect(report.focusGainResumeOk, isTrue);
      expect(report.becomingNoisyPauseOk, isTrue);
      expect(report.terminalPlayStatePausedBeforeReleaseOk, isTrue);
      expect(report.syntheticTransientLossPosted, equals(1));
      expect(report.syntheticFocusGainPosted, equals(1));
      expect(report.syntheticBecomingNoisyPosted, equals(1));
      expect(report.transientLossEventsEnqueued, equals(1));
      expect(report.focusGainEventsEnqueued, equals(1));
      expect(report.becomingNoisyEventsEnqueued, equals(1));
      expect(report.transientLossEventsDrained, equals(1));
      expect(report.focusGainEventsDrained, equals(1));
      expect(report.becomingNoisyEventsDrained, equals(1));
      expect(report.focusLossPauseResumeEventsDropped, equals(0));
      expect(report.transientLossAppliedCount, equals(1));
      expect(report.focusGainAppliedCount, equals(1));
      expect(report.becomingNoisyAppliedCount, equals(1));
      expect(report.transientPauseApplySeq, equals(0));
      expect(report.focusGainResumeApplySeq, equals(1));
      expect(report.noisyPauseApplySeq, equals(2));
      expect(
        report.transientPauseApplySeq,
        lessThan(report.focusGainResumeApplySeq),
      );
      expect(
        report.focusGainResumeApplySeq,
        lessThan(report.noisyPauseApplySeq),
      );
      expect(report.focusLossPauseResumeGatesHeld, isTrue);
      // Implied X7 and non-zero-gain gates hold too.
      expect(report.focusNoisyEventHandoffGatesHeld, isTrue);
      expect(report.nonZeroGainSinkGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X9 run must carry the focus-loss pause/resume pass marker', () {
      for (final wrongMarker in const [
        _kPassMarker,
        _kFocusNoisyPassMarker,
        _kFocusDuckRestorePassMarker,
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX9SampleRawMap({'marker': wrongMarker}),
            );
        expect(report.allNativeLanesPass, isFalse, reason: wrongMarker);
      }
    });

    test('X9 must carry its own proof boundary, not the default or X8 one', () {
      final defaultBoundary =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({'proofBoundary': _kCanonicalProofBoundary}),
          );
      expect(defaultBoundary.hasCanonicalProofBoundary, isFalse);
      expect(defaultBoundary.allNativeLanesPass, isFalse);

      final x8Boundary =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({
              'proofBoundary': _kFocusDuckRestoreProofBoundary,
            }),
          );
      expect(x8Boundary.hasCanonicalProofBoundary, isFalse);
      expect(x8Boundary.allNativeLanesPass, isFalse);
    });

    test('X9 requires focusLossPauseOk', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({'focusLossPauseOk': false}),
          );
      expect(report.focusLossPauseResumeGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X9 requires focusGainResumeOk', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({'focusGainResumeOk': false}),
          );
      expect(report.focusLossPauseResumeGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X9 requires becomingNoisyPauseOk', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({'becomingNoisyPauseOk': false}),
          );
      expect(report.focusLossPauseResumeGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X9 requires the terminal playstate paused before release', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({
              'terminalPlayStatePausedBeforeReleaseOk': false,
            }),
          );
      expect(report.focusLossPauseResumeGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X9 requires the focusLossPauseResumeGatesHeld native lane', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({'focusLossPauseResumeGatesHeld': false}),
          );
      expect(report.focusLossPauseResumeGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X9 requires exactly one applied event per tag', () {
      for (final key in const [
        'transientLossAppliedCount',
        'focusGainAppliedCount',
        'becomingNoisyAppliedCount',
      ]) {
        final missing =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX9SampleRawMap({key: 0}),
            );
        expect(missing.focusLossPauseResumeGatesHeld, isFalse, reason: key);
        expect(missing.allNativeLanesPass, isFalse, reason: key);

        final duplicate =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX9SampleRawMap({key: 2}),
            );
        expect(duplicate.focusLossPauseResumeGatesHeld, isFalse, reason: key);
        expect(duplicate.allNativeLanesPass, isFalse, reason: key);
      }
    });

    test('X9 requires per-tag posted/enqueued/drained counts of exactly 1', () {
      for (final key in const [
        'syntheticTransientLossPosted',
        'syntheticFocusGainPosted',
        'syntheticBecomingNoisyPosted',
        'transientLossEventsEnqueued',
        'focusGainEventsEnqueued',
        'becomingNoisyEventsEnqueued',
        'transientLossEventsDrained',
        'focusGainEventsDrained',
        'becomingNoisyEventsDrained',
      ]) {
        final zero =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX9SampleRawMap({key: 0}),
            );
        expect(zero.focusLossPauseResumeGatesHeld, isFalse, reason: key);
        expect(zero.allNativeLanesPass, isFalse, reason: key);

        final two =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX9SampleRawMap({key: 2}),
            );
        expect(two.focusLossPauseResumeGatesHeld, isFalse, reason: key);
        expect(two.allNativeLanesPass, isFalse, reason: key);
      }
    });

    test('X9 gate fails on dropped events', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({'focusLossPauseResumeEventsDropped': 1}),
          );
      expect(report.focusLossPauseResumeEventsDropped, equals(1));
      expect(report.focusLossPauseResumeGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X9 gate fails when the applied sequence is not strictly ordered '
        'transient < gain < noisy', () {
      final gainBeforePause =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({
              'transientPauseApplySeq': 1,
              'focusGainResumeApplySeq': 0,
            }),
          );
      expect(gainBeforePause.focusLossPauseResumeGatesHeld, isFalse);
      expect(gainBeforePause.allNativeLanesPass, isFalse);

      final noisyBeforeGain =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({
              'focusGainResumeApplySeq': 2,
              'noisyPauseApplySeq': 1,
            }),
          );
      expect(noisyBeforeGain.focusLossPauseResumeGatesHeld, isFalse);
      expect(noisyBeforeGain.allNativeLanesPass, isFalse);

      final equalSeq =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({
              'transientPauseApplySeq': 1,
              'focusGainResumeApplySeq': 1,
            }),
          );
      expect(equalSeq.focusLossPauseResumeGatesHeld, isFalse);
      expect(equalSeq.allNativeLanesPass, isFalse);

      final neverPaused =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({'transientPauseApplySeq': -1}),
          );
      expect(neverPaused.focusLossPauseResumeGatesHeld, isFalse);
      expect(neverPaused.allNativeLanesPass, isFalse);
    });

    test('X9 still requires the implied X7 focus/noisy gates', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({'audioFocusAbandonedOk': false}),
          );
      expect(report.focusNoisyEventHandoffGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X9 still requires the implied non-zero base gain', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX9SampleRawMap({
              'audioTrackGain': 0.0,
              'audioTrackNonZeroGainSetOk': false,
            }),
          );
      expect(report.nonZeroGainSinkGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X9 mode sends focusLossPauseResumeProofEnabled=true only', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return createX9SampleRawMap();
      });

      final report =
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: '/tmp/clip_B.mov',
            focusLossPauseResumeProofEnabled: true,
          );

      expect(capturedArgs?['focusLossPauseResumeProofEnabled'], isTrue);
      // The implied X7 flag is derived natively; the Dart wrapper never
      // sends it, the X8 flag, or any other mode flag for an X9 run.
      expect(
        capturedArgs?.containsKey('focusNoisyEventHandoffProofEnabled'),
        isFalse,
      );
      expect(
        capturedArgs?.containsKey('focusDuckRestoreProofEnabled'),
        isFalse,
      );
      expect(capturedArgs?.containsKey('envelopeProofEnabled'), isFalse);
      expect(capturedArgs?.containsKey('nonZeroGainSinkProofEnabled'), isFalse);
      expect(report.pass, isTrue);
      expect(report.focusLossPauseResumeProofEnabled, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test(
      'default X4 run does NOT send focusLossPauseResumeProofEnabled',
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
          capturedArgs?.containsKey('focusLossPauseResumeProofEnabled'),
          isFalse,
        );
      },
    );

    test('X8 run does NOT send focusLossPauseResumeProofEnabled', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createSampleRawMap();
      });

      await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
        sourcePath: '/tmp/clip_B.mov',
        focusDuckRestoreProofEnabled: true,
      );

      expect(capturedArgs?['focusDuckRestoreProofEnabled'], isTrue);
      expect(
        capturedArgs?.containsKey('focusLossPauseResumeProofEnabled'),
        isFalse,
      );
    });
  });

  group('X10 permanent focus-loss stop/no-auto-resume response proof mode', () {
    // X10 pass sample map: X4 base with the X10 marker, the X10 mode-specific
    // proof boundary, the implied X7 focus/noisy lanes/metrics, the implied
    // non-zero 0.5 base gain facts, and the X10 permanent focus-loss
    // lanes/metrics. X8 duck/restore and X9 transient pause/resume facts stay
    // at their defaults: X10 never enables X8 or X9.
    Map<String, Object?> createX10SampleRawMap([
      Map<String, Object?>? overrides,
    ]) {
      final result = _createSampleRawMap();
      result['marker'] = _kPermanentFocusLossPassMarker;
      result['proofBoundary'] = _kPermanentFocusLossProofBoundary;
      final rawStrings = result['raw'] as Map<String, String>;
      rawStrings['marker'] = _kPermanentFocusLossPassMarker;
      rawStrings['proofBoundary'] = _kPermanentFocusLossProofBoundary;
      final lanes = result['lanes'] as Map<String, Object?>;
      // X10 implies the non-zero base gain: the muted lane is honestly false.
      lanes['mutedOutputOk'] = false;
      // Implied X7 focus/noisy lanes.
      lanes['audioFocusRequestGrantedOk'] = true;
      lanes['audioFocusAbandonedOk'] = true;
      lanes['noisyReceiverRegisteredOk'] = true;
      lanes['noisyReceiverUnregisteredOk'] = true;
      lanes['focusNoisyOwnerThreadDrainOk'] = true;
      lanes['focusNoisyEventHandoffGatesHeld'] = true;
      // X10 coordinator lane.
      lanes['permanentFocusLossGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      // Implied X7 metrics.
      metrics['focusNoisyEventHandoffProofEnabled'] = true;
      metrics['focusNoisySyntheticEventsPosted'] = 2;
      metrics['focusNoisyEventsEnqueued'] = 2;
      metrics['focusNoisyEventsDropped'] = 0;
      metrics['focusNoisyEventsDrained'] = 2;
      // Implied non-zero 0.5 base gain facts (nonZeroGainSinkProofEnabled,
      // focusDuckRestoreProofEnabled, focusLossPauseResumeProofEnabled stay false).
      metrics['audioTrackGain'] = 0.5;
      metrics['audioTrackNonZeroGainSetOk'] = true;
      metrics['focusDuckRestoreProofEnabled'] = false;
      metrics['focusLossPauseResumeProofEnabled'] = false;
      // X10 driver metrics (sink-side playstate telemetry only).
      metrics['permanentFocusLossProofEnabled'] = true;
      metrics['permanentLossAppliedCount'] = 1;
      metrics['focusGainAttemptRejectedCount'] = 1;
      metrics['permanentFocusLossPauseOk'] = true;
      metrics['focusGainAutoResumeRejectedOk'] = true;
      metrics['autoResumeAllowed'] = false;
      metrics['permanentLossApplySeq'] = 0;
      metrics['focusGainAttemptApplySeq'] = 1;
      metrics['playStateAfterPermanentLossPause'] = 2;
      metrics['playStateAfterFocusGainAttempt'] = 2;
      metrics['playStateAtReleasePermanent'] = 2;
      metrics['terminalPlayStatePausedBeforeReleasePermanentOk'] = true;
      // X10 coordinator metrics.
      metrics['syntheticPermanentLossPosted'] = 1;
      metrics['syntheticFocusGainAttemptPosted'] = 1;
      metrics['permanentLossEventsEnqueued'] = 1;
      metrics['focusGainAttemptEventsEnqueued'] = 1;
      metrics['permanentLossEventsDrained'] = 1;
      metrics['focusGainAttemptEventsDrained'] = 1;
      metrics['permanentFocusLossEventsDropped'] = 0;
      metrics['permanentFocusLossRealFocusChangeCallbackCount'] = 0;
      if (overrides != null) {
        for (final entry in overrides.entries) {
          if (lanes.containsKey(entry.key)) lanes[entry.key] = entry.value;
          if (metrics.containsKey(entry.key)) metrics[entry.key] = entry.value;
          result[entry.key] = entry.value;
        }
      }
      return result;
    }

    test('default X4 pass report has permanentFocusLossProofEnabled=false '
        'and gate vacuously true', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap(),
          );
      expect(report.permanentFocusLossProofEnabled, isFalse);
      expect(report.permanentFocusLossPauseOk, isFalse);
      expect(report.focusGainAutoResumeRejectedOk, isFalse);
      expect(report.autoResumeAllowed, isFalse);
      expect(report.terminalPlayStatePausedBeforeReleasePermanentOk, isFalse);
      expect(report.syntheticPermanentLossPosted, equals(0));
      expect(report.syntheticFocusGainAttemptPosted, equals(0));
      expect(report.permanentLossAppliedCount, equals(-1));
      expect(report.focusGainAttemptRejectedCount, equals(-1));
      expect(report.permanentLossApplySeq, equals(-1));
      expect(report.focusGainAttemptApplySeq, equals(-1));
      expect(report.permanentFocusLossEventsDropped, equals(0));
      // Gate is vacuously true when X10 disabled.
      expect(report.permanentFocusLossGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X8 pass report keeps X10 defaults and still passes', () {
      final result = _createSampleRawMap();
      result['marker'] = _kFocusDuckRestorePassMarker;
      result['proofBoundary'] = _kFocusDuckRestoreProofBoundary;
      final rawStrings = result['raw'] as Map<String, String>;
      rawStrings['marker'] = _kFocusDuckRestorePassMarker;
      rawStrings['proofBoundary'] = _kFocusDuckRestoreProofBoundary;
      final lanes = result['lanes'] as Map<String, Object?>;
      lanes['mutedOutputOk'] = false;
      lanes['audioFocusRequestGrantedOk'] = true;
      lanes['audioFocusAbandonedOk'] = true;
      lanes['noisyReceiverRegisteredOk'] = true;
      lanes['noisyReceiverUnregisteredOk'] = true;
      lanes['focusNoisyOwnerThreadDrainOk'] = true;
      lanes['focusNoisyEventHandoffGatesHeld'] = true;
      lanes['focusListenerRegisteredOk'] = true;
      lanes['focusDuckRestoreGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      metrics['focusNoisyEventHandoffProofEnabled'] = true;
      metrics['focusNoisySyntheticEventsPosted'] = 2;
      metrics['focusNoisyEventsEnqueued'] = 2;
      metrics['focusNoisyEventsDropped'] = 0;
      metrics['focusNoisyEventsDrained'] = 2;
      metrics['audioTrackGain'] = 0.5;
      metrics['audioTrackNonZeroGainSetOk'] = true;
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
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            result,
          );
      expect(report.focusDuckRestoreProofEnabled, isTrue);
      expect(report.permanentFocusLossProofEnabled, isFalse);
      expect(report.permanentFocusLossGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X9 pass report keeps X10 defaults and still passes', () {
      final result = _createSampleRawMap();
      result['marker'] = _kFocusLossPauseResumePassMarker;
      result['proofBoundary'] = _kFocusLossPauseResumeProofBoundary;
      final rawStrings = result['raw'] as Map<String, String>;
      rawStrings['marker'] = _kFocusLossPauseResumePassMarker;
      rawStrings['proofBoundary'] = _kFocusLossPauseResumeProofBoundary;
      final lanes = result['lanes'] as Map<String, Object?>;
      lanes['mutedOutputOk'] = false;
      lanes['audioFocusRequestGrantedOk'] = true;
      lanes['audioFocusAbandonedOk'] = true;
      lanes['noisyReceiverRegisteredOk'] = true;
      lanes['noisyReceiverUnregisteredOk'] = true;
      lanes['focusNoisyOwnerThreadDrainOk'] = true;
      lanes['focusNoisyEventHandoffGatesHeld'] = true;
      lanes['focusLossPauseResumeGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      metrics['focusNoisyEventHandoffProofEnabled'] = true;
      metrics['focusNoisySyntheticEventsPosted'] = 2;
      metrics['focusNoisyEventsEnqueued'] = 2;
      metrics['focusNoisyEventsDropped'] = 0;
      metrics['focusNoisyEventsDrained'] = 2;
      metrics['audioTrackGain'] = 0.5;
      metrics['audioTrackNonZeroGainSetOk'] = true;
      metrics['focusDuckRestoreProofEnabled'] = false;
      metrics['focusLossPauseResumeProofEnabled'] = true;
      metrics['transientLossAppliedCount'] = 1;
      metrics['focusGainAppliedCount'] = 1;
      metrics['becomingNoisyAppliedCount'] = 1;
      metrics['focusLossPauseOk'] = true;
      metrics['focusGainResumeOk'] = true;
      metrics['becomingNoisyPauseOk'] = true;
      metrics['transientPauseApplySeq'] = 0;
      metrics['focusGainResumeApplySeq'] = 1;
      metrics['noisyPauseApplySeq'] = 2;
      metrics['playStateAfterTransientPause'] = 2;
      metrics['playStateAfterFocusGainResume'] = 3;
      metrics['playStateAfterNoisyPause'] = 2;
      metrics['playStateAtRelease'] = 2;
      metrics['terminalPlayStatePausedBeforeReleaseOk'] = true;
      metrics['syntheticTransientLossPosted'] = 1;
      metrics['syntheticFocusGainPosted'] = 1;
      metrics['syntheticBecomingNoisyPosted'] = 1;
      metrics['transientLossEventsEnqueued'] = 1;
      metrics['focusGainEventsEnqueued'] = 1;
      metrics['becomingNoisyEventsEnqueued'] = 1;
      metrics['transientLossEventsDrained'] = 1;
      metrics['focusGainEventsDrained'] = 1;
      metrics['becomingNoisyEventsDrained'] = 1;
      metrics['focusLossPauseResumeEventsDropped'] = 0;
      metrics['focusLossRealFocusChangeCallbackCount'] = 0;
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            result,
          );
      expect(report.focusLossPauseResumeProofEnabled, isTrue);
      expect(report.permanentFocusLossProofEnabled, isFalse);
      expect(report.permanentFocusLossGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X10 pass report passes all gates with permanent pause ok, gain '
        'attempt rejected, autoResumeAllowed=false, strictly ordered loss < '
        'gain attempt, and terminal playstate paused', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX10SampleRawMap(),
          );
      expect(report.marker, equals(_kPermanentFocusLossPassMarker));
      expect(report.proofBoundary, equals(_kPermanentFocusLossProofBoundary));
      expect(report.permanentFocusLossProofEnabled, isTrue);
      // X10 never enables X8 or X9.
      expect(report.focusDuckRestoreProofEnabled, isFalse);
      expect(report.focusDuckRestoreGatesHeld, isTrue);
      expect(report.focusLossPauseResumeProofEnabled, isFalse);
      expect(report.focusLossPauseResumeGatesHeld, isTrue);
      // X10 gates held.
      expect(report.permanentFocusLossPauseOk, isTrue);
      expect(report.focusGainAutoResumeRejectedOk, isTrue);
      expect(report.autoResumeAllowed, isFalse);
      expect(report.terminalPlayStatePausedBeforeReleasePermanentOk, isTrue);
      expect(report.syntheticPermanentLossPosted, equals(1));
      expect(report.syntheticFocusGainAttemptPosted, equals(1));
      expect(report.permanentLossEventsEnqueued, equals(1));
      expect(report.focusGainAttemptEventsEnqueued, equals(1));
      expect(report.permanentLossEventsDrained, equals(1));
      expect(report.focusGainAttemptEventsDrained, equals(1));
      expect(report.permanentFocusLossEventsDropped, equals(0));
      expect(report.permanentLossAppliedCount, equals(1));
      expect(report.focusGainAttemptRejectedCount, equals(1));
      expect(report.permanentLossApplySeq, equals(0));
      expect(report.focusGainAttemptApplySeq, equals(1));
      expect(
        report.permanentLossApplySeq,
        lessThan(report.focusGainAttemptApplySeq),
      );
      expect(report.permanentFocusLossGatesHeld, isTrue);
      // Implied X7 and non-zero-gain gates hold too.
      expect(report.focusNoisyEventHandoffGatesHeld, isTrue);
      expect(report.nonZeroGainSinkGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X10 run must carry the permanent focus-loss pass marker', () {
      for (final wrongMarker in const [
        _kPassMarker,
        _kFocusNoisyPassMarker,
        _kFocusDuckRestorePassMarker,
        _kFocusLossPauseResumePassMarker,
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX10SampleRawMap({'marker': wrongMarker}),
            );
        expect(report.allNativeLanesPass, isFalse, reason: wrongMarker);
      }
    });

    test(
      'X10 must carry its own proof boundary, not the default, X8, or X9 one',
      () {
        final defaultBoundary =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX10SampleRawMap({
                'proofBoundary': _kCanonicalProofBoundary,
              }),
            );
        expect(defaultBoundary.hasCanonicalProofBoundary, isFalse);
        expect(defaultBoundary.allNativeLanesPass, isFalse);

        final x8Boundary =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX10SampleRawMap({
                'proofBoundary': _kFocusDuckRestoreProofBoundary,
              }),
            );
        expect(x8Boundary.hasCanonicalProofBoundary, isFalse);
        expect(x8Boundary.allNativeLanesPass, isFalse);

        final x9Boundary =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX10SampleRawMap({
                'proofBoundary': _kFocusLossPauseResumeProofBoundary,
              }),
            );
        expect(x9Boundary.hasCanonicalProofBoundary, isFalse);
        expect(x9Boundary.allNativeLanesPass, isFalse);
      },
    );

    test('X10 requires permanentFocusLossPauseOk', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX10SampleRawMap({'permanentFocusLossPauseOk': false}),
          );
      expect(report.permanentFocusLossGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X10 requires focusGainAutoResumeRejectedOk', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX10SampleRawMap({'focusGainAutoResumeRejectedOk': false}),
          );
      expect(report.permanentFocusLossGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X10 gate fails when autoResumeAllowed is true', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX10SampleRawMap({'autoResumeAllowed': true}),
          );
      expect(report.autoResumeAllowed, isTrue);
      expect(report.permanentFocusLossGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X10 requires terminalPlayStatePausedBeforeReleasePermanentOk', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX10SampleRawMap({
              'terminalPlayStatePausedBeforeReleasePermanentOk': false,
            }),
          );
      expect(report.permanentFocusLossGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X10 requires the permanentFocusLossGatesHeld native lane', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX10SampleRawMap({'permanentFocusLossGatesHeld': false}),
          );
      expect(report.permanentFocusLossGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X10 requires exactly one applied event per tag', () {
      for (final key in const [
        'permanentLossAppliedCount',
        'focusGainAttemptRejectedCount',
      ]) {
        final missing =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX10SampleRawMap({key: 0}),
            );
        expect(missing.permanentFocusLossGatesHeld, isFalse, reason: key);
        expect(missing.allNativeLanesPass, isFalse, reason: key);

        final duplicate =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX10SampleRawMap({key: 2}),
            );
        expect(duplicate.permanentFocusLossGatesHeld, isFalse, reason: key);
        expect(duplicate.allNativeLanesPass, isFalse, reason: key);
      }
    });

    test(
      'X10 requires per-tag posted/enqueued/drained counts of exactly 1',
      () {
        for (final key in const [
          'syntheticPermanentLossPosted',
          'syntheticFocusGainAttemptPosted',
          'permanentLossEventsEnqueued',
          'focusGainAttemptEventsEnqueued',
          'permanentLossEventsDrained',
          'focusGainAttemptEventsDrained',
        ]) {
          final zero =
              VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
                createX10SampleRawMap({key: 0}),
              );
          expect(zero.permanentFocusLossGatesHeld, isFalse, reason: key);
          expect(zero.allNativeLanesPass, isFalse, reason: key);

          final two =
              VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
                createX10SampleRawMap({key: 2}),
              );
          expect(two.permanentFocusLossGatesHeld, isFalse, reason: key);
          expect(two.allNativeLanesPass, isFalse, reason: key);
        }
      },
    );

    test('X10 gate fails on dropped events', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX10SampleRawMap({'permanentFocusLossEventsDropped': 1}),
          );
      expect(report.permanentFocusLossEventsDropped, equals(1));
      expect(report.permanentFocusLossGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X10 gate fails when the applied sequence is not strictly ordered '
        'loss < gain attempt', () {
      final attemptBeforeLoss =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX10SampleRawMap({
              'permanentLossApplySeq': 1,
              'focusGainAttemptApplySeq': 0,
            }),
          );
      expect(attemptBeforeLoss.permanentFocusLossGatesHeld, isFalse);
      expect(attemptBeforeLoss.allNativeLanesPass, isFalse);

      final equalSeq =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX10SampleRawMap({
              'permanentLossApplySeq': 1,
              'focusGainAttemptApplySeq': 1,
            }),
          );
      expect(equalSeq.permanentFocusLossGatesHeld, isFalse);
      expect(equalSeq.allNativeLanesPass, isFalse);

      final neverPaused =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX10SampleRawMap({'permanentLossApplySeq': -1}),
          );
      expect(neverPaused.permanentFocusLossGatesHeld, isFalse);
      expect(neverPaused.allNativeLanesPass, isFalse);
    });

    test('X10 still requires the implied X7 focus/noisy gates', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX10SampleRawMap({'audioFocusAbandonedOk': false}),
          );
      expect(report.focusNoisyEventHandoffGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X10 still requires the implied non-zero base gain', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX10SampleRawMap({
              'audioTrackGain': 0.0,
              'audioTrackNonZeroGainSetOk': false,
            }),
          );
      expect(report.nonZeroGainSinkGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X10 mode sends permanentFocusLossProofEnabled=true only', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return createX10SampleRawMap();
      });

      final report =
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: '/tmp/clip_B.mov',
            permanentFocusLossProofEnabled: true,
          );

      expect(capturedArgs?['permanentFocusLossProofEnabled'], isTrue);
      // The implied X7 flag is derived natively; the Dart wrapper never
      // sends it, the X8 flag, the X9 flag, or any other mode flag for an X10 run.
      expect(
        capturedArgs?.containsKey('focusNoisyEventHandoffProofEnabled'),
        isFalse,
      );
      expect(
        capturedArgs?.containsKey('focusDuckRestoreProofEnabled'),
        isFalse,
      );
      expect(
        capturedArgs?.containsKey('focusLossPauseResumeProofEnabled'),
        isFalse,
      );
      expect(capturedArgs?.containsKey('envelopeProofEnabled'), isFalse);
      expect(capturedArgs?.containsKey('nonZeroGainSinkProofEnabled'), isFalse);
      expect(report.pass, isTrue);
      expect(report.permanentFocusLossProofEnabled, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('default X4 run does NOT send permanentFocusLossProofEnabled', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createSampleRawMap();
      });

      await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
        sourcePath: '/tmp/clip_B.mov',
      );

      expect(
        capturedArgs?.containsKey('permanentFocusLossProofEnabled'),
        isFalse,
      );
    });

    test('X8 run does NOT send permanentFocusLossProofEnabled', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createSampleRawMap();
      });

      await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
        sourcePath: '/tmp/clip_B.mov',
        focusDuckRestoreProofEnabled: true,
      );

      expect(capturedArgs?['focusDuckRestoreProofEnabled'], isTrue);
      expect(
        capturedArgs?.containsKey('permanentFocusLossProofEnabled'),
        isFalse,
      );
    });

    test('X9 run does NOT send permanentFocusLossProofEnabled', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createSampleRawMap();
      });

      await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
        sourcePath: '/tmp/clip_B.mov',
        focusLossPauseResumeProofEnabled: true,
      );

      expect(capturedArgs?['focusLossPauseResumeProofEnabled'], isTrue);
      expect(
        capturedArgs?.containsKey('permanentFocusLossProofEnabled'),
        isFalse,
      );
    });
  });

  group('X11 route-change event-handoff response proof mode', () {
    // X11 pass sample map: X4 base with the X11 marker, the X11 mode-specific
    // proof boundary, the implied X7 focus/noisy lanes/metrics, the implied
    // non-zero 0.5 base gain facts, and the X11 route-change lanes/metrics.
    // X8 duck/restore, X9 transient pause/resume and X10 permanent-stop facts
    // stay at their defaults: X11 never enables X8, X9 or X10.
    Map<String, Object?> createX11SampleRawMap([
      Map<String, Object?>? overrides,
    ]) {
      final result = _createSampleRawMap();
      result['marker'] = _kRouteChangeEventHandoffPassMarker;
      result['proofBoundary'] = _kRouteChangeEventHandoffProofBoundary;
      final rawStrings = result['raw'] as Map<String, String>;
      rawStrings['marker'] = _kRouteChangeEventHandoffPassMarker;
      rawStrings['proofBoundary'] = _kRouteChangeEventHandoffProofBoundary;
      final lanes = result['lanes'] as Map<String, Object?>;
      // X11 implies the non-zero base gain: the muted lane is honestly false.
      lanes['mutedOutputOk'] = false;
      // Implied X7 focus/noisy lanes.
      lanes['audioFocusRequestGrantedOk'] = true;
      lanes['audioFocusAbandonedOk'] = true;
      lanes['noisyReceiverRegisteredOk'] = true;
      lanes['noisyReceiverUnregisteredOk'] = true;
      lanes['focusNoisyOwnerThreadDrainOk'] = true;
      lanes['focusNoisyEventHandoffGatesHeld'] = true;
      // X11 driver lanes.
      lanes['routingListenerRegisteredOk'] = true;
      lanes['routingListenerUnregisteredOk'] = true;
      lanes['routeChangeObservationOk'] = true;
      lanes['routeDisconnectFailClosedPauseOk'] = true;
      lanes['terminalPlayStatePausedBeforeReleaseRouteChangeOk'] = true;
      // X11 coordinator lane.
      lanes['routeChangeEventHandoffGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      // Implied X7 metrics.
      metrics['focusNoisyEventHandoffProofEnabled'] = true;
      metrics['focusNoisySyntheticEventsPosted'] = 2;
      metrics['focusNoisyEventsEnqueued'] = 2;
      metrics['focusNoisyEventsDropped'] = 0;
      metrics['focusNoisyEventsDrained'] = 2;
      // Implied non-zero 0.5 base gain facts (nonZeroGainSinkProofEnabled,
      // focusDuckRestoreProofEnabled, focusLossPauseResumeProofEnabled and
      // permanentFocusLossProofEnabled stay false).
      metrics['audioTrackGain'] = 0.5;
      metrics['audioTrackNonZeroGainSetOk'] = true;
      metrics['focusDuckRestoreProofEnabled'] = false;
      metrics['focusLossPauseResumeProofEnabled'] = false;
      metrics['permanentFocusLossProofEnabled'] = false;
      // X11 driver metrics (sink-side routed-device/playstate telemetry only).
      metrics['routeChangeEventHandoffProofEnabled'] = true;
      metrics['routeChangedAppliedCount'] = 1;
      metrics['routeDisconnectAppliedCount'] = 1;
      metrics['routeChangedApplySeq'] = 0;
      metrics['routeDisconnectApplySeq'] = 1;
      metrics['routedDeviceSampleOk'] = true;
      metrics['routedDeviceTypeAtRouteChanged'] = 2;
      metrics['playStateAfterRouteDisconnectPause'] = 2;
      metrics['playStateAtReleaseRouteChange'] = 2;
      // X11 coordinator metrics.
      metrics['syntheticRouteChangedPosted'] = 1;
      metrics['syntheticRouteDisconnectPosted'] = 1;
      metrics['routeChangedEventsEnqueued'] = 1;
      metrics['routeDisconnectEventsEnqueued'] = 1;
      metrics['routeChangedEventsDrained'] = 1;
      metrics['routeDisconnectEventsDrained'] = 1;
      metrics['routeChangeEventsDropped'] = 0;
      metrics['realRoutingChangedCallbackCount'] = 0;
      if (overrides != null) {
        for (final entry in overrides.entries) {
          if (lanes.containsKey(entry.key)) lanes[entry.key] = entry.value;
          if (metrics.containsKey(entry.key)) metrics[entry.key] = entry.value;
          result[entry.key] = entry.value;
        }
      }
      return result;
    }

    test('default X4 pass report has routeChangeEventHandoffProofEnabled=false '
        'and gate vacuously true', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap(),
          );
      expect(report.routeChangeEventHandoffProofEnabled, isFalse);
      expect(report.routingListenerRegisteredOk, isFalse);
      expect(report.routingListenerUnregisteredOk, isFalse);
      expect(report.routeChangeObservationOk, isFalse);
      expect(report.routeDisconnectFailClosedPauseOk, isFalse);
      expect(report.terminalPlayStatePausedBeforeReleaseRouteChangeOk, isFalse);
      expect(report.syntheticRouteChangedPosted, equals(0));
      expect(report.syntheticRouteDisconnectPosted, equals(0));
      expect(report.routeChangedEventsEnqueued, equals(-1));
      expect(report.routeDisconnectEventsEnqueued, equals(-1));
      expect(report.routeChangedEventsDrained, equals(-1));
      expect(report.routeDisconnectEventsDrained, equals(-1));
      expect(report.routeChangeEventsDropped, equals(0));
      expect(report.routeChangedAppliedCount, equals(-1));
      expect(report.routeDisconnectAppliedCount, equals(-1));
      expect(report.routeChangedApplySeq, equals(-1));
      expect(report.routeDisconnectApplySeq, equals(-1));
      expect(report.realRoutingChangedCallbackCount, equals(0));
      expect(report.playStateAfterRouteDisconnectPause, equals(-1));
      expect(report.playStateAtReleaseRouteChange, equals(-1));
      // Gate is vacuously true when X11 disabled.
      expect(report.routeChangeEventHandoffGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X10 pass report keeps X11 defaults and still passes', () {
      final result = _createSampleRawMap();
      result['marker'] = _kPermanentFocusLossPassMarker;
      result['proofBoundary'] = _kPermanentFocusLossProofBoundary;
      final rawStrings = result['raw'] as Map<String, String>;
      rawStrings['marker'] = _kPermanentFocusLossPassMarker;
      rawStrings['proofBoundary'] = _kPermanentFocusLossProofBoundary;
      final lanes = result['lanes'] as Map<String, Object?>;
      lanes['mutedOutputOk'] = false;
      lanes['audioFocusRequestGrantedOk'] = true;
      lanes['audioFocusAbandonedOk'] = true;
      lanes['noisyReceiverRegisteredOk'] = true;
      lanes['noisyReceiverUnregisteredOk'] = true;
      lanes['focusNoisyOwnerThreadDrainOk'] = true;
      lanes['focusNoisyEventHandoffGatesHeld'] = true;
      lanes['permanentFocusLossGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      metrics['focusNoisyEventHandoffProofEnabled'] = true;
      metrics['focusNoisySyntheticEventsPosted'] = 2;
      metrics['focusNoisyEventsEnqueued'] = 2;
      metrics['focusNoisyEventsDropped'] = 0;
      metrics['focusNoisyEventsDrained'] = 2;
      metrics['audioTrackGain'] = 0.5;
      metrics['audioTrackNonZeroGainSetOk'] = true;
      metrics['focusDuckRestoreProofEnabled'] = false;
      metrics['focusLossPauseResumeProofEnabled'] = false;
      metrics['permanentFocusLossProofEnabled'] = true;
      metrics['permanentLossAppliedCount'] = 1;
      metrics['focusGainAttemptRejectedCount'] = 1;
      metrics['permanentFocusLossPauseOk'] = true;
      metrics['focusGainAutoResumeRejectedOk'] = true;
      metrics['autoResumeAllowed'] = false;
      metrics['permanentLossApplySeq'] = 0;
      metrics['focusGainAttemptApplySeq'] = 1;
      metrics['playStateAfterPermanentLossPause'] = 2;
      metrics['playStateAfterFocusGainAttempt'] = 2;
      metrics['playStateAtReleasePermanent'] = 2;
      metrics['terminalPlayStatePausedBeforeReleasePermanentOk'] = true;
      metrics['syntheticPermanentLossPosted'] = 1;
      metrics['syntheticFocusGainAttemptPosted'] = 1;
      metrics['permanentLossEventsEnqueued'] = 1;
      metrics['focusGainAttemptEventsEnqueued'] = 1;
      metrics['permanentLossEventsDrained'] = 1;
      metrics['focusGainAttemptEventsDrained'] = 1;
      metrics['permanentFocusLossEventsDropped'] = 0;
      metrics['permanentFocusLossRealFocusChangeCallbackCount'] = 0;
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            result,
          );
      expect(report.permanentFocusLossProofEnabled, isTrue);
      expect(report.routeChangeEventHandoffProofEnabled, isFalse);
      expect(report.routeChangeEventHandoffGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X11 pass report passes all gates with listener registered and '
        'unregistered, route_changed observed, route_disconnect pause ok, '
        'strictly ordered route_changed < route_disconnect, and terminal '
        'playstate paused', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap(),
          );
      expect(report.marker, equals(_kRouteChangeEventHandoffPassMarker));
      expect(
        report.proofBoundary,
        equals(_kRouteChangeEventHandoffProofBoundary),
      );
      expect(report.routeChangeEventHandoffProofEnabled, isTrue);
      // X11 never enables X8, X9 or X10.
      expect(report.focusDuckRestoreProofEnabled, isFalse);
      expect(report.focusDuckRestoreGatesHeld, isTrue);
      expect(report.focusLossPauseResumeProofEnabled, isFalse);
      expect(report.focusLossPauseResumeGatesHeld, isTrue);
      expect(report.permanentFocusLossProofEnabled, isFalse);
      expect(report.permanentFocusLossGatesHeld, isTrue);
      // X11 gates held.
      expect(report.routingListenerRegisteredOk, isTrue);
      expect(report.routingListenerUnregisteredOk, isTrue);
      expect(report.routeChangeObservationOk, isTrue);
      expect(report.routeDisconnectFailClosedPauseOk, isTrue);
      expect(report.terminalPlayStatePausedBeforeReleaseRouteChangeOk, isTrue);
      expect(report.syntheticRouteChangedPosted, equals(1));
      expect(report.syntheticRouteDisconnectPosted, equals(1));
      expect(report.routeChangedEventsEnqueued, equals(1));
      expect(report.routeDisconnectEventsEnqueued, equals(1));
      expect(report.routeChangedEventsDrained, equals(1));
      expect(report.routeDisconnectEventsDrained, equals(1));
      expect(report.routeChangeEventsDropped, equals(0));
      expect(report.routeChangedAppliedCount, equals(1));
      expect(report.routeDisconnectAppliedCount, equals(1));
      expect(report.routeChangedApplySeq, equals(0));
      expect(report.routeDisconnectApplySeq, equals(1));
      expect(
        report.routeChangedApplySeq,
        lessThan(report.routeDisconnectApplySeq),
      );
      expect(report.realRoutingChangedCallbackCount, equals(0));
      expect(report.playStateAfterRouteDisconnectPause, equals(2));
      expect(report.playStateAtReleaseRouteChange, equals(2));
      expect(report.routeChangeEventHandoffGatesHeld, isTrue);
      // Implied X7 and non-zero-gain gates hold too.
      expect(report.focusNoisyEventHandoffGatesHeld, isTrue);
      expect(report.nonZeroGainSinkGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X11 pass report tolerates a real routing-callback handoff that '
        'was drained and observed before the disconnect', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({
              'realRoutingChangedCallbackCount': 1,
              'routeChangedEventsEnqueued': 2,
              'routeChangedEventsDrained': 2,
              'routeChangedAppliedCount': 2,
              'routeDisconnectApplySeq': 2,
            }),
          );
      expect(report.realRoutingChangedCallbackCount, equals(1));
      expect(report.routeChangeEventHandoffGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X11 run must carry the route-change event-handoff pass marker', () {
      for (final wrongMarker in const [
        _kPassMarker,
        _kFocusNoisyPassMarker,
        _kFocusDuckRestorePassMarker,
        _kFocusLossPauseResumePassMarker,
        _kPermanentFocusLossPassMarker,
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX11SampleRawMap({'marker': wrongMarker}),
            );
        expect(report.allNativeLanesPass, isFalse, reason: wrongMarker);
      }
    });

    test('X11 must carry its own proof boundary, not the default, X8, X9, or '
        'X10 one', () {
      for (final wrongBoundary in const [
        _kCanonicalProofBoundary,
        _kFocusDuckRestoreProofBoundary,
        _kFocusLossPauseResumeProofBoundary,
        _kPermanentFocusLossProofBoundary,
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX11SampleRawMap({'proofBoundary': wrongBoundary}),
            );
        expect(
          report.hasCanonicalProofBoundary,
          isFalse,
          reason: wrongBoundary,
        );
        expect(report.allNativeLanesPass, isFalse, reason: wrongBoundary);
      }
    });

    test('X11 requires every route-change lane boolean', () {
      for (final lane in const [
        'routingListenerRegisteredOk',
        'routingListenerUnregisteredOk',
        'routeChangeObservationOk',
        'routeDisconnectFailClosedPauseOk',
        'terminalPlayStatePausedBeforeReleaseRouteChangeOk',
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX11SampleRawMap({lane: false}),
            );
        expect(report.routeChangeEventHandoffGatesHeld, isFalse, reason: lane);
        expect(report.allNativeLanesPass, isFalse, reason: lane);
      }
    });

    test('X11 requires the routeChangeEventHandoffGatesHeld native lane', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({'routeChangeEventHandoffGatesHeld': false}),
          );
      expect(report.routeChangeEventHandoffGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X11 requires exactly one applied route_disconnect', () {
      final missing =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({'routeDisconnectAppliedCount': 0}),
          );
      expect(missing.routeChangeEventHandoffGatesHeld, isFalse);
      expect(missing.allNativeLanesPass, isFalse);

      final duplicate =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({'routeDisconnectAppliedCount': 2}),
          );
      expect(duplicate.routeChangeEventHandoffGatesHeld, isFalse);
      expect(duplicate.allNativeLanesPass, isFalse);
    });

    test('X11 requires every drained route_changed to be observed, at least '
        'once', () {
      final missing =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({'routeChangedAppliedCount': 0}),
          );
      expect(missing.routeChangeEventHandoffGatesHeld, isFalse);
      expect(missing.allNativeLanesPass, isFalse);

      // Applied twice while only one was drained: duplicate observation.
      final duplicate =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({'routeChangedAppliedCount': 2}),
          );
      expect(duplicate.routeChangeEventHandoffGatesHeld, isFalse);
      expect(duplicate.allNativeLanesPass, isFalse);
    });

    test('X11 requires per-tag synthetic posted and route_disconnect '
        'enqueued/drained counts of exactly 1', () {
      for (final key in const [
        'syntheticRouteChangedPosted',
        'syntheticRouteDisconnectPosted',
        'routeDisconnectEventsEnqueued',
        'routeDisconnectEventsDrained',
      ]) {
        final zero =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX11SampleRawMap({key: 0}),
            );
        expect(zero.routeChangeEventHandoffGatesHeld, isFalse, reason: key);
        expect(zero.allNativeLanesPass, isFalse, reason: key);

        final two =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX11SampleRawMap({key: 2}),
            );
        expect(two.routeChangeEventHandoffGatesHeld, isFalse, reason: key);
        expect(two.allNativeLanesPass, isFalse, reason: key);
      }
    });

    test('X11 requires route_changed enqueued/drained accounting: at least '
        'one, bounded by the real callback count, fully drained', () {
      // Never enqueued: the synthetic pre-start event was lost.
      final missing =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({
              'routeChangedEventsEnqueued': 0,
              'routeChangedEventsDrained': 0,
              'routeChangedAppliedCount': 0,
            }),
          );
      expect(missing.routeChangeEventHandoffGatesHeld, isFalse);
      expect(missing.allNativeLanesPass, isFalse);

      // Two enqueued with zero real callbacks: a duplicate synthetic post.
      final duplicate =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({
              'routeChangedEventsEnqueued': 2,
              'routeChangedEventsDrained': 2,
              'routeChangedAppliedCount': 2,
              'routeDisconnectApplySeq': 2,
            }),
          );
      expect(duplicate.routeChangeEventHandoffGatesHeld, isFalse);
      expect(duplicate.allNativeLanesPass, isFalse);

      // Enqueued but never drained on the owner thread.
      final undrained =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({'routeChangedEventsDrained': 0}),
          );
      expect(undrained.routeChangeEventHandoffGatesHeld, isFalse);
      expect(undrained.allNativeLanesPass, isFalse);

      // Drained more than enqueued.
      final overDrained =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({'routeChangedEventsDrained': 2}),
          );
      expect(overDrained.routeChangeEventHandoffGatesHeld, isFalse);
      expect(overDrained.allNativeLanesPass, isFalse);
    });

    test('X11 gate fails on dropped events', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({'routeChangeEventsDropped': 1}),
          );
      expect(report.routeChangeEventsDropped, equals(1));
      expect(report.routeChangeEventHandoffGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X11 gate fails when the applied sequence is not strictly ordered '
        'route_changed < route_disconnect with the disconnect last', () {
      final disconnectBeforeChanged =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({
              'routeChangedApplySeq': 1,
              'routeDisconnectApplySeq': 0,
            }),
          );
      expect(disconnectBeforeChanged.routeChangeEventHandoffGatesHeld, isFalse);
      expect(disconnectBeforeChanged.allNativeLanesPass, isFalse);

      final equalSeq =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({
              'routeChangedApplySeq': 1,
              'routeDisconnectApplySeq': 1,
            }),
          );
      expect(equalSeq.routeChangeEventHandoffGatesHeld, isFalse);
      expect(equalSeq.allNativeLanesPass, isFalse);

      final neverObserved =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({'routeChangedApplySeq': -1}),
          );
      expect(neverObserved.routeChangeEventHandoffGatesHeld, isFalse);
      expect(neverObserved.allNativeLanesPass, isFalse);

      // The disconnect ordinal must equal the observed route_changed count:
      // anything else means an event was applied after the disconnect.
      final notLast =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({'routeDisconnectApplySeq': 2}),
          );
      expect(notLast.routeChangeEventHandoffGatesHeld, isFalse);
      expect(notLast.allNativeLanesPass, isFalse);
    });

    test('X11 still requires the implied X7 focus/noisy gates', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({'audioFocusAbandonedOk': false}),
          );
      expect(report.focusNoisyEventHandoffGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X11 still requires the implied non-zero base gain', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX11SampleRawMap({
              'audioTrackGain': 0.0,
              'audioTrackNonZeroGainSetOk': false,
            }),
          );
      expect(report.nonZeroGainSinkGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test(
      'X11 mode sends routeChangeEventHandoffProofEnabled=true only',
      () async {
        Map<String, Object?>? capturedArgs;

        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedArgs = (call.arguments as Map).cast<String, Object?>();
          return createX11SampleRawMap();
        });

        final report =
            await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
              sourcePath: '/tmp/clip_B.mov',
              routeChangeEventHandoffProofEnabled: true,
            );

        expect(capturedArgs?['routeChangeEventHandoffProofEnabled'], isTrue);
        // The implied X7 flag is derived natively; the Dart wrapper never
        // sends it, the X8, X9 or X10 flags, or any other mode flag for an
        // X11 run.
        expect(
          capturedArgs?.containsKey('focusNoisyEventHandoffProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('focusDuckRestoreProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('focusLossPauseResumeProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('permanentFocusLossProofEnabled'),
          isFalse,
        );
        expect(capturedArgs?.containsKey('envelopeProofEnabled'), isFalse);
        expect(
          capturedArgs?.containsKey('nonZeroGainSinkProofEnabled'),
          isFalse,
        );
        expect(report.pass, isTrue);
        expect(report.routeChangeEventHandoffProofEnabled, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test(
      'default X4 run does NOT send routeChangeEventHandoffProofEnabled',
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
          capturedArgs?.containsKey('routeChangeEventHandoffProofEnabled'),
          isFalse,
        );
      },
    );

    test(
      'X8, X9 and X10 runs do NOT send routeChangeEventHandoffProofEnabled',
      () async {
        Map<String, Object?>? capturedArgs;

        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedArgs = (call.arguments as Map).cast<String, Object?>();
          return _createSampleRawMap();
        });

        await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
          sourcePath: '/tmp/clip_B.mov',
          focusDuckRestoreProofEnabled: true,
        );
        expect(capturedArgs?['focusDuckRestoreProofEnabled'], isTrue);
        expect(
          capturedArgs?.containsKey('routeChangeEventHandoffProofEnabled'),
          isFalse,
        );

        await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
          sourcePath: '/tmp/clip_B.mov',
          focusLossPauseResumeProofEnabled: true,
        );
        expect(capturedArgs?['focusLossPauseResumeProofEnabled'], isTrue);
        expect(
          capturedArgs?.containsKey('routeChangeEventHandoffProofEnabled'),
          isFalse,
        );

        await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
          sourcePath: '/tmp/clip_B.mov',
          permanentFocusLossProofEnabled: true,
        );
        expect(capturedArgs?['permanentFocusLossProofEnabled'], isTrue);
        expect(
          capturedArgs?.containsKey('routeChangeEventHandoffProofEnabled'),
          isFalse,
        );
      },
    );
  });

  group('X12 dead-object recovery response proof mode', () {
    // X12 pass sample map: X4 base with the X12 marker, the X12 mode-specific
    // proof boundary, the implied non-zero 0.5 base gain facts, and the X12
    // dead-object recovery lanes/metrics. X12 is isolated: X7 focus/noisy,
    // X8 duck/restore, X9 transient pause/resume, X10 permanent-stop and X11
    // route-change facts all stay at their defaults. The dead object is a
    // SYNTHETIC injection; the sample geometry places it in the post-seek
    // epoch after 62208 sink frames (57600 pre-seek + 4608 post-seek) with
    // the remaining 21760 frames written to the recreated track.
    Map<String, Object?> createX12SampleRawMap([
      Map<String, Object?>? overrides,
    ]) {
      final result = _createSampleRawMap();
      result['marker'] = _kDeadObjectRecoveryPassMarker;
      result['proofBoundary'] = _kDeadObjectRecoveryProofBoundary;
      final rawStrings = result['raw'] as Map<String, String>;
      rawStrings['marker'] = _kDeadObjectRecoveryPassMarker;
      rawStrings['proofBoundary'] = _kDeadObjectRecoveryProofBoundary;
      final lanes = result['lanes'] as Map<String, Object?>;
      // X12 implies the non-zero base gain: the muted lane is honestly false.
      lanes['mutedOutputOk'] = false;
      // X12 driver lanes.
      lanes['deadObjectOldTrackReleasedOk'] = true;
      lanes['deadObjectNewTrackStateInitializedOk'] = true;
      lanes['deadObjectNewTrackVolumeSetOk'] = true;
      lanes['deadObjectNewTrackPlayOk'] = true;
      lanes['deadObjectRecoveryGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      // Implied non-zero 0.5 base gain facts (nonZeroGainSinkProofEnabled,
      // focusNoisyEventHandoffProofEnabled, focusDuckRestoreProofEnabled,
      // focusLossPauseResumeProofEnabled, permanentFocusLossProofEnabled and
      // routeChangeEventHandoffProofEnabled stay false).
      metrics['audioTrackGain'] = 0.5;
      metrics['audioTrackNonZeroGainSetOk'] = true;
      metrics['focusNoisyEventHandoffProofEnabled'] = false;
      metrics['focusDuckRestoreProofEnabled'] = false;
      metrics['focusLossPauseResumeProofEnabled'] = false;
      metrics['permanentFocusLossProofEnabled'] = false;
      metrics['routeChangeEventHandoffProofEnabled'] = false;
      // X12 driver metrics (sink-side accounting/playstate telemetry only).
      metrics['deadObjectRecoveryProofEnabled'] = true;
      metrics['deadObjectOccurredCount'] = 1;
      metrics['syntheticDeadObjectInjectedCount'] = 1;
      metrics['deadObjectOldTrackReleaseCount'] = 1;
      metrics['deadObjectTrackCreateCount'] = 2;
      metrics['deadObjectSliceBytesAtRecovery'] = 16384;
      metrics['deadObjectUnwrittenBytesAtRecovery'] = 16384;
      metrics['deadObjectSinkFramesWrittenBeforeRecovery'] = 62208;
      metrics['deadObjectEpochFramesWrittenBeforeRecovery'] = 4608;
      metrics['deadObjectSinkFramesWrittenAfterRecovery'] = 21760;
      metrics['playStateAfterDeadObjectRecreatePlay'] = 3;
      metrics['playStateAtReleaseDeadObject'] = 3;
      if (overrides != null) {
        for (final entry in overrides.entries) {
          if (lanes.containsKey(entry.key)) lanes[entry.key] = entry.value;
          if (metrics.containsKey(entry.key)) metrics[entry.key] = entry.value;
          result[entry.key] = entry.value;
        }
      }
      return result;
    }

    test('default X4 pass report has deadObjectRecoveryProofEnabled=false '
        'and gate vacuously true', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap(),
          );
      expect(report.deadObjectRecoveryProofEnabled, isFalse);
      expect(report.deadObjectOldTrackReleasedOk, isFalse);
      expect(report.deadObjectNewTrackStateInitializedOk, isFalse);
      expect(report.deadObjectNewTrackVolumeSetOk, isFalse);
      expect(report.deadObjectNewTrackPlayOk, isFalse);
      expect(report.deadObjectOccurredCount, equals(0));
      expect(report.syntheticDeadObjectInjectedCount, equals(0));
      expect(report.deadObjectOldTrackReleaseCount, equals(0));
      expect(report.deadObjectTrackCreateCount, equals(0));
      expect(report.deadObjectSliceBytesAtRecovery, equals(-1));
      expect(report.deadObjectUnwrittenBytesAtRecovery, equals(-1));
      expect(report.deadObjectSinkFramesWrittenBeforeRecovery, equals(-1));
      expect(report.deadObjectSinkFramesWrittenAfterRecovery, equals(-1));
      expect(report.playStateAfterDeadObjectRecreatePlay, equals(-1));
      expect(report.playStateAtReleaseDeadObject, equals(-1));
      // Gate is vacuously true when X12 disabled.
      expect(report.deadObjectRecoveryGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X11 pass report keeps X12 defaults and still passes', () {
      final result = _createSampleRawMap();
      result['marker'] = _kRouteChangeEventHandoffPassMarker;
      result['proofBoundary'] = _kRouteChangeEventHandoffProofBoundary;
      final rawStrings = result['raw'] as Map<String, String>;
      rawStrings['marker'] = _kRouteChangeEventHandoffPassMarker;
      rawStrings['proofBoundary'] = _kRouteChangeEventHandoffProofBoundary;
      final lanes = result['lanes'] as Map<String, Object?>;
      lanes['mutedOutputOk'] = false;
      lanes['audioFocusRequestGrantedOk'] = true;
      lanes['audioFocusAbandonedOk'] = true;
      lanes['noisyReceiverRegisteredOk'] = true;
      lanes['noisyReceiverUnregisteredOk'] = true;
      lanes['focusNoisyOwnerThreadDrainOk'] = true;
      lanes['focusNoisyEventHandoffGatesHeld'] = true;
      lanes['routingListenerRegisteredOk'] = true;
      lanes['routingListenerUnregisteredOk'] = true;
      lanes['routeChangeObservationOk'] = true;
      lanes['routeDisconnectFailClosedPauseOk'] = true;
      lanes['terminalPlayStatePausedBeforeReleaseRouteChangeOk'] = true;
      lanes['routeChangeEventHandoffGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      metrics['focusNoisyEventHandoffProofEnabled'] = true;
      metrics['focusNoisySyntheticEventsPosted'] = 2;
      metrics['focusNoisyEventsEnqueued'] = 2;
      metrics['focusNoisyEventsDropped'] = 0;
      metrics['focusNoisyEventsDrained'] = 2;
      metrics['audioTrackGain'] = 0.5;
      metrics['audioTrackNonZeroGainSetOk'] = true;
      metrics['routeChangeEventHandoffProofEnabled'] = true;
      metrics['routeChangedAppliedCount'] = 1;
      metrics['routeDisconnectAppliedCount'] = 1;
      metrics['routeChangedApplySeq'] = 0;
      metrics['routeDisconnectApplySeq'] = 1;
      metrics['syntheticRouteChangedPosted'] = 1;
      metrics['syntheticRouteDisconnectPosted'] = 1;
      metrics['routeChangedEventsEnqueued'] = 1;
      metrics['routeDisconnectEventsEnqueued'] = 1;
      metrics['routeChangedEventsDrained'] = 1;
      metrics['routeDisconnectEventsDrained'] = 1;
      metrics['routeChangeEventsDropped'] = 0;
      metrics['realRoutingChangedCallbackCount'] = 0;
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            result,
          );
      expect(report.routeChangeEventHandoffProofEnabled, isTrue);
      expect(report.deadObjectRecoveryProofEnabled, isFalse);
      expect(report.deadObjectRecoveryGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X12 pass report passes all gates with one synthetic dead object, '
        'old track released once, recreated track initialized, gain set, '
        'playing, and the unwritten slice resumed', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX12SampleRawMap(),
          );
      expect(report.marker, equals(_kDeadObjectRecoveryPassMarker));
      expect(report.proofBoundary, equals(_kDeadObjectRecoveryProofBoundary));
      expect(report.deadObjectRecoveryProofEnabled, isTrue);
      // X12 is isolated: X7, X8, X9, X10 and X11 stay disabled.
      expect(report.focusNoisyEventHandoffProofEnabled, isFalse);
      expect(report.focusNoisyEventHandoffGatesHeld, isTrue);
      expect(report.focusDuckRestoreProofEnabled, isFalse);
      expect(report.focusDuckRestoreGatesHeld, isTrue);
      expect(report.focusLossPauseResumeProofEnabled, isFalse);
      expect(report.focusLossPauseResumeGatesHeld, isTrue);
      expect(report.permanentFocusLossProofEnabled, isFalse);
      expect(report.permanentFocusLossGatesHeld, isTrue);
      expect(report.routeChangeEventHandoffProofEnabled, isFalse);
      expect(report.routeChangeEventHandoffGatesHeld, isTrue);
      // X12 gates held.
      expect(report.deadObjectOccurredCount, equals(1));
      expect(report.syntheticDeadObjectInjectedCount, equals(1));
      expect(report.deadObjectOldTrackReleasedOk, isTrue);
      expect(report.deadObjectOldTrackReleaseCount, equals(1));
      expect(report.deadObjectTrackCreateCount, equals(2));
      expect(report.deadObjectNewTrackStateInitializedOk, isTrue);
      expect(report.deadObjectNewTrackVolumeSetOk, isTrue);
      expect(report.deadObjectNewTrackPlayOk, isTrue);
      expect(report.deadObjectSliceBytesAtRecovery, equals(16384));
      expect(report.deadObjectUnwrittenBytesAtRecovery, equals(16384));
      expect(report.deadObjectSinkFramesWrittenBeforeRecovery, equals(62208));
      expect(report.deadObjectSinkFramesWrittenAfterRecovery, equals(21760));
      expect(
        report.deadObjectSinkFramesWrittenBeforeRecovery +
            report.deadObjectSinkFramesWrittenAfterRecovery,
        equals(report.framesWrittenToSink),
      );
      expect(report.playStateAfterDeadObjectRecreatePlay, equals(3));
      expect(report.playStateAtReleaseDeadObject, equals(3));
      expect(report.deadObjectRecoveryGatesHeld, isTrue);
      // Implied non-zero-gain gate holds; accounting/identity untouched.
      expect(report.nonZeroGainSinkGatesHeld, isTrue);
      expect(report.audioTrackGain, equals(0.5));
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.frameAccountingOk, isTrue);
      expect(report.checksumsMatch, isTrue);
      expect(report.realtimeGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.nativeProofBoundaryOk, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X12 run must carry the dead-object recovery pass marker', () {
      for (final wrongMarker in const [
        _kPassMarker,
        _kNonZeroGainPassMarker,
        _kFocusNoisyPassMarker,
        _kFocusDuckRestorePassMarker,
        _kFocusLossPauseResumePassMarker,
        _kPermanentFocusLossPassMarker,
        _kRouteChangeEventHandoffPassMarker,
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX12SampleRawMap({'marker': wrongMarker}),
            );
        expect(report.allNativeLanesPass, isFalse, reason: wrongMarker);
      }
    });

    test('X12 must carry its own proof boundary, not the default, X8, X9, '
        'X10, or X11 one', () {
      for (final wrongBoundary in const [
        _kCanonicalProofBoundary,
        _kFocusDuckRestoreProofBoundary,
        _kFocusLossPauseResumeProofBoundary,
        _kPermanentFocusLossProofBoundary,
        _kRouteChangeEventHandoffProofBoundary,
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX12SampleRawMap({'proofBoundary': wrongBoundary}),
            );
        expect(
          report.hasCanonicalProofBoundary,
          isFalse,
          reason: wrongBoundary,
        );
        expect(report.allNativeLanesPass, isFalse, reason: wrongBoundary);
      }
    });

    test('X12 requires every dead-object recovery lane boolean', () {
      for (final lane in const [
        'deadObjectOldTrackReleasedOk',
        'deadObjectNewTrackStateInitializedOk',
        'deadObjectNewTrackVolumeSetOk',
        'deadObjectNewTrackPlayOk',
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX12SampleRawMap({lane: false}),
            );
        expect(report.deadObjectRecoveryGatesHeld, isFalse, reason: lane);
        expect(report.allNativeLanesPass, isFalse, reason: lane);
      }
    });

    test('X12 requires the deadObjectRecoveryGatesHeld native lane', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX12SampleRawMap({'deadObjectRecoveryGatesHeld': false}),
          );
      expect(report.deadObjectRecoveryGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X12 requires the synthetic dead object injected and observed '
        'exactly once and the old track released exactly once', () {
      for (final key in const [
        'deadObjectOccurredCount',
        'syntheticDeadObjectInjectedCount',
        'deadObjectOldTrackReleaseCount',
      ]) {
        final zero =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX12SampleRawMap({key: 0}),
            );
        expect(zero.deadObjectRecoveryGatesHeld, isFalse, reason: key);
        expect(zero.allNativeLanesPass, isFalse, reason: key);

        // A second observation (e.g. a real OS dead object in the same run,
        // or a duplicate injection/release) fails closed.
        final two =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX12SampleRawMap({key: 2}),
            );
        expect(two.deadObjectRecoveryGatesHeld, isFalse, reason: key);
        expect(two.allNativeLanesPass, isFalse, reason: key);
      }
    });

    test('X12 requires exactly two track builds (original plus one '
        'recreation)', () {
      for (final count in const [0, 1, 3]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX12SampleRawMap({'deadObjectTrackCreateCount': count}),
            );
        expect(report.deadObjectRecoveryGatesHeld, isFalse, reason: '$count');
        expect(report.allNativeLanesPass, isFalse, reason: '$count');
      }
    });

    test('X12 requires a non-empty unwritten remainder bounded by the slice '
        'to have been resumed', () {
      final empty =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX12SampleRawMap({'deadObjectUnwrittenBytesAtRecovery': 0}),
          );
      expect(empty.deadObjectRecoveryGatesHeld, isFalse);
      expect(empty.allNativeLanesPass, isFalse);

      final never =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX12SampleRawMap({'deadObjectUnwrittenBytesAtRecovery': -1}),
          );
      expect(never.deadObjectRecoveryGatesHeld, isFalse);
      expect(never.allNativeLanesPass, isFalse);

      final overSlice =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX12SampleRawMap({
              'deadObjectUnwrittenBytesAtRecovery': 16385,
            }),
          );
      expect(overSlice.deadObjectRecoveryGatesHeld, isFalse);
      expect(overSlice.allNativeLanesPass, isFalse);

      // A mid-slice remainder (partial write before the injection) is fine.
      final midSlice =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX12SampleRawMap({'deadObjectUnwrittenBytesAtRecovery': 8192}),
          );
      expect(midSlice.deadObjectRecoveryGatesHeld, isTrue);
      expect(midSlice.allNativeLanesPass, isTrue);
    });

    test('X12 requires sink frames before and after the recovery to be '
        'positive and to sum to the sink total (no drop, no double count)', () {
      final nothingBefore =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX12SampleRawMap({
              'deadObjectSinkFramesWrittenBeforeRecovery': 0,
              'deadObjectSinkFramesWrittenAfterRecovery': 83968,
            }),
          );
      expect(nothingBefore.deadObjectRecoveryGatesHeld, isFalse);
      expect(nothingBefore.allNativeLanesPass, isFalse);

      final nothingAfter =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX12SampleRawMap({
              'deadObjectSinkFramesWrittenBeforeRecovery': 83968,
              'deadObjectSinkFramesWrittenAfterRecovery': 0,
            }),
          );
      expect(nothingAfter.deadObjectRecoveryGatesHeld, isFalse);
      expect(nothingAfter.allNativeLanesPass, isFalse);

      // Dropped frames: the split no longer sums to the sink total.
      final dropped =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX12SampleRawMap({
              'deadObjectSinkFramesWrittenAfterRecovery': 21504,
            }),
          );
      expect(dropped.deadObjectRecoveryGatesHeld, isFalse);
      expect(dropped.allNativeLanesPass, isFalse);

      // Double-counted frames: the split overshoots the sink total.
      final doubled =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX12SampleRawMap({
              'deadObjectSinkFramesWrittenAfterRecovery': 25856,
            }),
          );
      expect(doubled.deadObjectRecoveryGatesHeld, isFalse);
      expect(doubled.allNativeLanesPass, isFalse);
    });

    test('X12 requires the sink accounting, checksum identity, and frame '
        'accounting lanes to survive the recovery', () {
      for (final lane in const [
        'sinkWriteAccountingOk',
        'checksumIdentityOk',
        'frameAccountingOk',
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX12SampleRawMap({lane: false}),
            );
        expect(report.deadObjectRecoveryGatesHeld, isFalse, reason: lane);
        expect(report.allNativeLanesPass, isFalse, reason: lane);
      }

      final mismatch =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX12SampleRawMap({
              'kotlinSinkWriteChecksumHex': '00000000deadbeef',
            }),
          );
      expect(mismatch.checksumsMatch, isFalse);
      expect(mismatch.allNativeLanesPass, isFalse);
    });

    test('X12 still requires the implied non-zero base gain', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX12SampleRawMap({
              'audioTrackGain': 0.0,
              'audioTrackNonZeroGainSetOk': false,
            }),
          );
      expect(report.nonZeroGainSinkGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X12 fail report surfaces the fail-closed recovery reason', () {
      final report = VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
        createX12SampleRawMap({
          'pass': false,
          'status': 'recreated_audio_track_not_initialized',
          'marker':
              'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_DEAD_OBJECT_RECOVERY_PHYSICAL_SMOKE_FAIL',
          'failureReason': 'recreated_audio_track_not_initialized',
          'lastError': 'recreated_audio_track_not_initialized',
          'deadObjectNewTrackStateInitializedOk': false,
          'deadObjectNewTrackVolumeSetOk': false,
          'deadObjectNewTrackPlayOk': false,
          'deadObjectRecoveryGatesHeld': false,
        }),
      );
      expect(report.pass, isFalse);
      expect(
        report.marker,
        equals(
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
              .deadObjectRecoveryFailMarkerConstant,
        ),
      );
      expect(report.deadObjectOldTrackReleasedOk, isTrue);
      expect(report.deadObjectNewTrackStateInitializedOk, isFalse);
      expect(report.deadObjectRecoveryGatesHeld, isFalse);
      expect(report.lastError, equals('recreated_audio_track_not_initialized'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X12 mode sends deadObjectRecoveryProofEnabled=true only', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return createX12SampleRawMap();
      });

      final report =
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: '/tmp/clip_B.mov',
            deadObjectRecoveryProofEnabled: true,
          );

      expect(capturedArgs?['deadObjectRecoveryProofEnabled'], isTrue);
      // X12 is isolated: the Dart wrapper never sends X7, X8, X9, X10,
      // X11, or any other mode flag for an X12 run.
      expect(
        capturedArgs?.containsKey('focusNoisyEventHandoffProofEnabled'),
        isFalse,
      );
      expect(
        capturedArgs?.containsKey('focusDuckRestoreProofEnabled'),
        isFalse,
      );
      expect(
        capturedArgs?.containsKey('focusLossPauseResumeProofEnabled'),
        isFalse,
      );
      expect(
        capturedArgs?.containsKey('permanentFocusLossProofEnabled'),
        isFalse,
      );
      expect(
        capturedArgs?.containsKey('routeChangeEventHandoffProofEnabled'),
        isFalse,
      );
      expect(capturedArgs?.containsKey('envelopeProofEnabled'), isFalse);
      expect(capturedArgs?.containsKey('nonZeroGainSinkProofEnabled'), isFalse);
      expect(report.pass, isTrue);
      expect(report.deadObjectRecoveryProofEnabled, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('default X4 run does NOT send deadObjectRecoveryProofEnabled', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createSampleRawMap();
      });

      await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
        sourcePath: '/tmp/clip_B.mov',
      );

      expect(
        capturedArgs?.containsKey('deadObjectRecoveryProofEnabled'),
        isFalse,
      );
    });

    test('X6 and X11 runs do NOT send deadObjectRecoveryProofEnabled', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createSampleRawMap();
      });

      await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
        sourcePath: '/tmp/clip_B.mov',
        nonZeroGainSinkProofEnabled: true,
      );
      expect(capturedArgs?['nonZeroGainSinkProofEnabled'], isTrue);
      expect(
        capturedArgs?.containsKey('deadObjectRecoveryProofEnabled'),
        isFalse,
      );

      await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
        sourcePath: '/tmp/clip_B.mov',
        routeChangeEventHandoffProofEnabled: true,
      );
      expect(capturedArgs?['routeChangeEventHandoffProofEnabled'], isTrue);
      expect(
        capturedArgs?.containsKey('deadObjectRecoveryProofEnabled'),
        isFalse,
      );
    });
  });

  group('X13 AudioTrack timestamp stabilization proof mode', () {
    // X13 standalone pass sample map: X4 base with X13 marker, X13 standalone
    // proof boundary (muted sink), X13 lanes, and X13 metrics (2 generations:
    // pre-seek and post-seek).
    Map<String, Object?> createX13SampleRawMap([
      Map<String, Object?>? overrides,
    ]) {
      final result = _createSampleRawMap();
      result['marker'] = _kTimestampStabilizationPassMarker;
      result['proofBoundary'] = _kTimestampStabilizationProofBoundary;
      final rawStrings = result['raw'] as Map<String, String>;
      rawStrings['marker'] = _kTimestampStabilizationPassMarker;
      rawStrings['proofBoundary'] = _kTimestampStabilizationProofBoundary;
      final lanes = result['lanes'] as Map<String, Object?>;
      lanes['timestampStabilizedOk'] = true;
      lanes['timestampAdvancingMonotonicOk'] = true;
      lanes['timestampPostSeekRestabilizedOk'] = true;
      lanes['timestampNoPacingFeedbackOk'] = true;
      lanes['timestampStabilizationGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      metrics['timestampStabilizationProofEnabled'] = true;
      metrics['timestampWarmupPollCount'] = 8;
      metrics['timestampStablePollCount'] = 320;
      metrics['timestampUnavailableAfterStableCount'] = 0;
      metrics['timestampPassCount'] = 328;
      metrics['timestampPassPollCount'] = 328;
      metrics['timestampPollInsideWriteLoopCount'] = 0;
      metrics['timestampFrameAdvanceCount'] = 310;
      metrics['timestampFrameEqualCount'] = 10;
      metrics['timestampFrameRegressionCount'] = 0;
      metrics['timestampWrapCount'] = 0;
      metrics['timestampNanoTimeAdvanceCountTelemetryOnly'] = 320;
      metrics['timestampNanoTimeEqualCountTelemetryOnly'] = 0;
      metrics['timestampNanoTimeNonMonotonicCountTelemetryOnly'] = 0;
      metrics['timestampEpochOpenCount'] = 2;
      metrics['timestampRecreateResetCount'] = 0;
      metrics['timestampGenerationCount'] = 2;
      metrics['timestampGenerationsStabilized'] = 2;
      metrics['timestampPreSeekStabilized'] = true;
      metrics['timestampPostSeekStabilized'] = true;
      metrics['timestampPostRecreateStabilized'] = false;
      metrics['timestampPreSeekWarmupPolls'] = 4;
      metrics['timestampPostSeekWarmupPolls'] = 4;
      metrics['timestampPostRecreateWarmupPolls'] = 0;
      metrics['timestampPreSeekStablePolls'] = 220;
      metrics['timestampPostSeekStablePolls'] = 100;
      metrics['timestampPostRecreateStablePolls'] = 0;
      metrics['timestampPreSeekAdvanceCount'] = 215;
      metrics['timestampPostSeekAdvanceCount'] = 95;
      metrics['timestampPostRecreateAdvanceCount'] = 0;
      metrics['timestampPreSeekFirstStableFramePosition'] = 1024;
      metrics['timestampPostSeekFirstStableFramePosition'] = 2048;
      metrics['timestampPostRecreateFirstStableFramePosition'] = -1;
      metrics['timestampLastFramePosition'] = 83968;
      metrics['timestampWarmupBudgetMs'] = 1000;
      metrics['timestampWarmupMaxPolls'] = 4096;
      if (overrides != null) {
        for (final entry in overrides.entries) {
          if (lanes.containsKey(entry.key)) lanes[entry.key] = entry.value;
          if (metrics.containsKey(entry.key)) metrics[entry.key] = entry.value;
          result[entry.key] = entry.value;
        }
      }
      return result;
    }

    // X13 + X12 composed pass sample map: X12 base (deadObjectRecoveryProofEnabled,
    // audioTrackGain 0.5, synthetic dead object injected once, recreated track)
    // with X13 marker, X13+X12 composed proof boundary, X13 lanes, and X13 metrics
    // across all 3 generations (pre-seek, post-seek, post-recreate).
    Map<String, Object?> createX13DeadObjectSampleRawMap([
      Map<String, Object?>? overrides,
    ]) {
      final result = _createSampleRawMap();
      result['marker'] = _kTimestampStabilizationPassMarker;
      result['proofBoundary'] =
          _kTimestampStabilizationDeadObjectRecoveryProofBoundary;
      final rawStrings = result['raw'] as Map<String, String>;
      rawStrings['marker'] = _kTimestampStabilizationPassMarker;
      rawStrings['proofBoundary'] =
          _kTimestampStabilizationDeadObjectRecoveryProofBoundary;
      final lanes = result['lanes'] as Map<String, Object?>;
      lanes['mutedOutputOk'] = false;
      // X12 driver lanes.
      lanes['deadObjectOldTrackReleasedOk'] = true;
      lanes['deadObjectNewTrackStateInitializedOk'] = true;
      lanes['deadObjectNewTrackVolumeSetOk'] = true;
      lanes['deadObjectNewTrackPlayOk'] = true;
      lanes['deadObjectRecoveryGatesHeld'] = true;
      // X13 driver lanes.
      lanes['timestampStabilizedOk'] = true;
      lanes['timestampAdvancingMonotonicOk'] = true;
      lanes['timestampPostSeekRestabilizedOk'] = true;
      lanes['timestampNoPacingFeedbackOk'] = true;
      lanes['timestampStabilizationGatesHeld'] = true;
      final metrics = result['metrics'] as Map<String, Object?>;
      metrics['audioTrackGain'] = 0.5;
      metrics['audioTrackNonZeroGainSetOk'] = true;
      metrics['deadObjectRecoveryProofEnabled'] = true;
      metrics['deadObjectOccurredCount'] = 1;
      metrics['syntheticDeadObjectInjectedCount'] = 1;
      metrics['deadObjectOldTrackReleaseCount'] = 1;
      metrics['deadObjectTrackCreateCount'] = 2;
      metrics['deadObjectSliceBytesAtRecovery'] = 16384;
      metrics['deadObjectUnwrittenBytesAtRecovery'] = 16384;
      metrics['deadObjectSinkFramesWrittenBeforeRecovery'] = 62208;
      metrics['deadObjectEpochFramesWrittenBeforeRecovery'] = 4608;
      metrics['deadObjectSinkFramesWrittenAfterRecovery'] = 21760;
      metrics['playStateAfterDeadObjectRecreatePlay'] = 3;
      metrics['playStateAtReleaseDeadObject'] = 3;
      // X13 metrics for 3 generations.
      metrics['timestampStabilizationProofEnabled'] = true;
      metrics['timestampWarmupPollCount'] = 12;
      metrics['timestampStablePollCount'] = 316;
      metrics['timestampUnavailableAfterStableCount'] = 0;
      metrics['timestampPassCount'] = 328;
      metrics['timestampPassPollCount'] = 328;
      metrics['timestampPollInsideWriteLoopCount'] = 0;
      metrics['timestampFrameAdvanceCount'] = 306;
      metrics['timestampFrameEqualCount'] = 10;
      metrics['timestampFrameRegressionCount'] = 0;
      metrics['timestampWrapCount'] = 0;
      metrics['timestampNanoTimeAdvanceCountTelemetryOnly'] = 316;
      metrics['timestampNanoTimeEqualCountTelemetryOnly'] = 0;
      metrics['timestampNanoTimeNonMonotonicCountTelemetryOnly'] = 0;
      metrics['timestampEpochOpenCount'] = 2;
      metrics['timestampRecreateResetCount'] = 1;
      metrics['timestampGenerationCount'] = 3;
      metrics['timestampGenerationsStabilized'] = 3;
      metrics['timestampPreSeekStabilized'] = true;
      metrics['timestampPostSeekStabilized'] = true;
      metrics['timestampPostRecreateStabilized'] = true;
      metrics['timestampPreSeekWarmupPolls'] = 4;
      metrics['timestampPostSeekWarmupPolls'] = 4;
      metrics['timestampPostRecreateWarmupPolls'] = 4;
      metrics['timestampPreSeekStablePolls'] = 220;
      metrics['timestampPostSeekStablePolls'] = 16;
      metrics['timestampPostRecreateStablePolls'] = 80;
      metrics['timestampPreSeekAdvanceCount'] = 215;
      metrics['timestampPostSeekAdvanceCount'] = 15;
      metrics['timestampPostRecreateAdvanceCount'] = 76;
      metrics['timestampPreSeekFirstStableFramePosition'] = 1024;
      metrics['timestampPostSeekFirstStableFramePosition'] = 2048;
      metrics['timestampPostRecreateFirstStableFramePosition'] = 512;
      metrics['timestampLastFramePosition'] = 83968;
      metrics['timestampWarmupBudgetMs'] = 1000;
      metrics['timestampWarmupMaxPolls'] = 4096;
      if (overrides != null) {
        for (final entry in overrides.entries) {
          if (lanes.containsKey(entry.key)) lanes[entry.key] = entry.value;
          if (metrics.containsKey(entry.key)) metrics[entry.key] = entry.value;
          result[entry.key] = entry.value;
        }
      }
      return result;
    }

    test('default X4 pass report has timestampStabilizationProofEnabled=false '
        'and gate vacuously true', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap(),
          );
      expect(report.timestampStabilizationProofEnabled, isFalse);
      expect(report.timestampStabilizedOk, isFalse);
      expect(report.timestampAdvancingMonotonicOk, isFalse);
      expect(report.timestampPostSeekRestabilizedOk, isFalse);
      expect(report.timestampNoPacingFeedbackOk, isFalse);
      expect(report.timestampWarmupPollCount, equals(0));
      expect(report.timestampStablePollCount, equals(0));
      expect(report.timestampUnavailableAfterStableCount, equals(0));
      expect(report.timestampPassCount, equals(0));
      expect(report.timestampPassPollCount, equals(0));
      expect(report.timestampPollInsideWriteLoopCount, equals(0));
      expect(report.timestampFrameAdvanceCount, equals(0));
      expect(report.timestampFrameEqualCount, equals(0));
      expect(report.timestampFrameRegressionCount, equals(0));
      expect(report.timestampWrapCount, equals(0));
      expect(report.timestampNanoTimeAdvanceCountTelemetryOnly, equals(0));
      expect(report.timestampNanoTimeEqualCountTelemetryOnly, equals(0));
      expect(report.timestampNanoTimeNonMonotonicCountTelemetryOnly, equals(0));
      expect(report.timestampEpochOpenCount, equals(0));
      expect(report.timestampRecreateResetCount, equals(0));
      expect(report.timestampGenerationCount, equals(0));
      expect(report.timestampGenerationsStabilized, equals(0));
      expect(report.timestampPreSeekStabilized, isFalse);
      expect(report.timestampPostSeekStabilized, isFalse);
      expect(report.timestampPostRecreateStabilized, isFalse);
      expect(report.timestampPreSeekWarmupPolls, equals(0));
      expect(report.timestampPostSeekWarmupPolls, equals(0));
      expect(report.timestampPostRecreateWarmupPolls, equals(0));
      expect(report.timestampPreSeekStablePolls, equals(0));
      expect(report.timestampPostSeekStablePolls, equals(0));
      expect(report.timestampPostRecreateStablePolls, equals(0));
      expect(report.timestampPreSeekAdvanceCount, equals(0));
      expect(report.timestampPostSeekAdvanceCount, equals(0));
      expect(report.timestampPostRecreateAdvanceCount, equals(0));
      expect(report.timestampPreSeekFirstStableFramePosition, equals(-1));
      expect(report.timestampPostSeekFirstStableFramePosition, equals(-1));
      expect(report.timestampPostRecreateFirstStableFramePosition, equals(-1));
      expect(report.timestampLastFramePosition, equals(-1));
      expect(report.timestampWarmupBudgetMs, equals(0));
      expect(report.timestampWarmupMaxPolls, equals(0));
      expect(report.timestampStabilizationGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X12 pass report keeps X13 defaults and still passes', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX13DeadObjectSampleRawMap({
              'marker': _kDeadObjectRecoveryPassMarker,
              'proofBoundary': _kDeadObjectRecoveryProofBoundary,
              'timestampStabilizationProofEnabled': false,
            }),
          );
      expect(report.deadObjectRecoveryProofEnabled, isTrue);
      expect(report.timestampStabilizationProofEnabled, isFalse);
      expect(report.timestampStabilizationGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X13 standalone pass report passes all gates with 2 generations, '
        'muted sink, monotonic framePosition, and zero feedback', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX13SampleRawMap(),
          );
      expect(report.marker, equals(_kTimestampStabilizationPassMarker));
      expect(
        report.proofBoundary,
        equals(_kTimestampStabilizationProofBoundary),
      );
      expect(report.timestampStabilizationProofEnabled, isTrue);
      expect(report.deadObjectRecoveryProofEnabled, isFalse);
      // X13 driver lanes.
      expect(report.timestampStabilizedOk, isTrue);
      expect(report.timestampAdvancingMonotonicOk, isTrue);
      expect(report.timestampPostSeekRestabilizedOk, isTrue);
      expect(report.timestampNoPacingFeedbackOk, isTrue);
      // Generation stabilization facts.
      expect(report.timestampPreSeekStabilized, isTrue);
      expect(report.timestampPostSeekStabilized, isTrue);
      expect(report.timestampPostRecreateStabilized, isFalse);
      expect(report.timestampGenerationCount, equals(2));
      expect(report.timestampGenerationsStabilized, equals(2));
      expect(report.timestampEpochOpenCount, equals(2));
      expect(report.timestampRecreateResetCount, equals(0));
      // Polls & advances.
      expect(report.timestampWarmupPollCount, equals(8));
      expect(report.timestampStablePollCount, equals(320));
      expect(report.timestampPreSeekWarmupPolls, equals(4));
      expect(report.timestampPostSeekWarmupPolls, equals(4));
      expect(report.timestampPreSeekStablePolls, equals(220));
      expect(report.timestampPostSeekStablePolls, equals(100));
      expect(report.timestampPreSeekAdvanceCount, equals(215));
      expect(report.timestampPostSeekAdvanceCount, equals(95));
      expect(report.timestampPreSeekFirstStableFramePosition, equals(1024));
      expect(report.timestampPostSeekFirstStableFramePosition, equals(2048));
      expect(report.timestampPostRecreateFirstStableFramePosition, equals(-1));
      expect(report.timestampLastFramePosition, equals(83968));
      expect(report.timestampFrameRegressionCount, equals(0));
      expect(report.timestampPollInsideWriteLoopCount, equals(0));
      expect(report.timestampPassPollCount, equals(report.timestampPassCount));
      // Muted sink preserved in standalone mode.
      expect(report.mutedOutputOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.frameAccountingOk, isTrue);
      expect(report.checksumsMatch, isTrue);
      expect(report.realtimeGatesHeld, isTrue);
      expect(report.timestampStabilizationGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.nativeProofBoundaryOk, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X13 + X12 composed pass report passes all gates with 3 generations, '
        'post-recreate reset, 0.5 gain, and X12 dead-object recovery held', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX13DeadObjectSampleRawMap(),
          );
      expect(report.marker, equals(_kTimestampStabilizationPassMarker));
      expect(
        report.proofBoundary,
        equals(_kTimestampStabilizationDeadObjectRecoveryProofBoundary),
      );
      expect(report.timestampStabilizationProofEnabled, isTrue);
      expect(report.deadObjectRecoveryProofEnabled, isTrue);
      // X12 dead-object recovery lanes held.
      expect(report.deadObjectOldTrackReleasedOk, isTrue);
      expect(report.deadObjectNewTrackStateInitializedOk, isTrue);
      expect(report.deadObjectNewTrackVolumeSetOk, isTrue);
      expect(report.deadObjectNewTrackPlayOk, isTrue);
      expect(report.deadObjectRecoveryGatesHeld, isTrue);
      expect(report.audioTrackGain, equals(0.5));
      // X13 driver lanes held across 3 generations.
      expect(report.timestampStabilizedOk, isTrue);
      expect(report.timestampAdvancingMonotonicOk, isTrue);
      expect(report.timestampPostSeekRestabilizedOk, isTrue);
      expect(report.timestampNoPacingFeedbackOk, isTrue);
      expect(report.timestampPreSeekStabilized, isTrue);
      expect(report.timestampPostSeekStabilized, isTrue);
      expect(report.timestampPostRecreateStabilized, isTrue);
      expect(report.timestampGenerationCount, equals(3));
      expect(report.timestampGenerationsStabilized, equals(3));
      expect(report.timestampEpochOpenCount, equals(2));
      expect(report.timestampRecreateResetCount, equals(1));
      expect(report.timestampPreSeekWarmupPolls, equals(4));
      expect(report.timestampPostSeekWarmupPolls, equals(4));
      expect(report.timestampPostRecreateWarmupPolls, equals(4));
      expect(report.timestampPreSeekStablePolls, equals(220));
      expect(report.timestampPostSeekStablePolls, equals(16));
      expect(report.timestampPostRecreateStablePolls, equals(80));
      expect(report.timestampPreSeekAdvanceCount, equals(215));
      expect(report.timestampPostSeekAdvanceCount, equals(15));
      expect(report.timestampPostRecreateAdvanceCount, equals(76));
      expect(report.timestampPreSeekFirstStableFramePosition, equals(1024));
      expect(report.timestampPostSeekFirstStableFramePosition, equals(2048));
      expect(report.timestampPostRecreateFirstStableFramePosition, equals(512));
      expect(report.timestampLastFramePosition, equals(83968));
      expect(report.timestampFrameRegressionCount, equals(0));
      expect(report.timestampPollInsideWriteLoopCount, equals(0));
      expect(report.timestampPassPollCount, equals(report.timestampPassCount));
      expect(report.timestampStabilizationGatesHeld, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.frameAccountingOk, isTrue);
      expect(report.checksumsMatch, isTrue);
      expect(report.realtimeGatesHeld, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.nativeProofBoundaryOk, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('X13 standalone and X13+X12 runs must carry the timestamp '
        'stabilization pass marker', () {
      for (final wrongMarker in const [
        _kPassMarker,
        _kNonZeroGainPassMarker,
        _kFocusNoisyPassMarker,
        _kFocusDuckRestorePassMarker,
        _kFocusLossPauseResumePassMarker,
        _kPermanentFocusLossPassMarker,
        _kRouteChangeEventHandoffPassMarker,
        _kDeadObjectRecoveryPassMarker,
      ]) {
        final standaloneReport =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13SampleRawMap({'marker': wrongMarker}),
            );
        expect(
          standaloneReport.allNativeLanesPass,
          isFalse,
          reason: wrongMarker,
        );

        final composedReport =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13DeadObjectSampleRawMap({'marker': wrongMarker}),
            );
        expect(composedReport.allNativeLanesPass, isFalse, reason: wrongMarker);
      }
    });

    test('X13 standalone must carry its own proof boundary, not X4, X8..X12, '
        'or X13+X12 boundary', () {
      for (final wrongBoundary in const [
        _kCanonicalProofBoundary,
        _kFocusDuckRestoreProofBoundary,
        _kFocusLossPauseResumeProofBoundary,
        _kPermanentFocusLossProofBoundary,
        _kRouteChangeEventHandoffProofBoundary,
        _kDeadObjectRecoveryProofBoundary,
        _kTimestampStabilizationDeadObjectRecoveryProofBoundary,
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13SampleRawMap({'proofBoundary': wrongBoundary}),
            );
        expect(
          report.hasCanonicalProofBoundary,
          isFalse,
          reason: wrongBoundary,
        );
        expect(report.allNativeLanesPass, isFalse, reason: wrongBoundary);
      }
    });

    test('X13 + X12 must carry the composite proof boundary, not X4, X12, '
        'or X13 standalone boundary', () {
      for (final wrongBoundary in const [
        _kCanonicalProofBoundary,
        _kDeadObjectRecoveryProofBoundary,
        _kTimestampStabilizationProofBoundary,
        _kRouteChangeEventHandoffProofBoundary,
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13DeadObjectSampleRawMap({'proofBoundary': wrongBoundary}),
            );
        expect(
          report.hasCanonicalProofBoundary,
          isFalse,
          reason: wrongBoundary,
        );
        expect(report.allNativeLanesPass, isFalse, reason: wrongBoundary);
      }
    });

    test('X13 requires every timestamp stabilization lane boolean', () {
      for (final lane in const [
        'timestampStabilizedOk',
        'timestampAdvancingMonotonicOk',
        'timestampPostSeekRestabilizedOk',
        'timestampNoPacingFeedbackOk',
      ]) {
        final standaloneReport =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13SampleRawMap({lane: false}),
            );
        expect(
          standaloneReport.timestampStabilizationGatesHeld,
          isFalse,
          reason: lane,
        );
        expect(standaloneReport.allNativeLanesPass, isFalse, reason: lane);

        final composedReport =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13DeadObjectSampleRawMap({lane: false}),
            );
        expect(
          composedReport.timestampStabilizationGatesHeld,
          isFalse,
          reason: lane,
        );
        expect(composedReport.allNativeLanesPass, isFalse, reason: lane);
      }
    });

    test('X13 requires timestampStabilizationGatesHeld native lane', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX13SampleRawMap({'timestampStabilizationGatesHeld': false}),
          );
      expect(report.timestampStabilizationGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isFalse);
    });

    test(
      'X13 standalone requires pre-seek and post-seek generations stabilized, '
      'exactly 2 generations and 0 recreate resets',
      () {
        final noPreSeek =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13SampleRawMap({'timestampPreSeekStabilized': false}),
            );
        expect(noPreSeek.timestampStabilizationGatesHeld, isFalse);
        expect(noPreSeek.allNativeLanesPass, isFalse);

        final noPostSeek =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13SampleRawMap({'timestampPostSeekStabilized': false}),
            );
        expect(noPostSeek.timestampStabilizationGatesHeld, isFalse);
        expect(noPostSeek.allNativeLanesPass, isFalse);

        final wrongGenCount =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13SampleRawMap({'timestampGenerationCount': 3}),
            );
        expect(wrongGenCount.timestampStabilizationGatesHeld, isFalse);
        expect(wrongGenCount.allNativeLanesPass, isFalse);

        final unexpectedRecreateReset =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13SampleRawMap({'timestampRecreateResetCount': 1}),
            );
        expect(
          unexpectedRecreateReset.timestampStabilizationGatesHeld,
          isFalse,
        );
        expect(unexpectedRecreateReset.allNativeLanesPass, isFalse);

        final wrongEpochOpen =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13SampleRawMap({'timestampEpochOpenCount': 1}),
            );
        expect(wrongEpochOpen.timestampStabilizationGatesHeld, isFalse);
        expect(wrongEpochOpen.allNativeLanesPass, isFalse);
      },
    );

    test(
      'X13 + X12 requires all 3 generations stabilized, exactly 3 generations '
      'and 1 recreate reset',
      () {
        final noPostRecreate =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13DeadObjectSampleRawMap({
                'timestampPostRecreateStabilized': false,
              }),
            );
        expect(noPostRecreate.timestampStabilizationGatesHeld, isFalse);
        expect(noPostRecreate.allNativeLanesPass, isFalse);

        final wrongGenCount =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13DeadObjectSampleRawMap({'timestampGenerationCount': 2}),
            );
        expect(wrongGenCount.timestampStabilizationGatesHeld, isFalse);
        expect(wrongGenCount.allNativeLanesPass, isFalse);

        final missingRecreateReset =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13DeadObjectSampleRawMap({
                'timestampRecreateResetCount': 0,
              }),
            );
        expect(missingRecreateReset.timestampStabilizationGatesHeld, isFalse);
        expect(missingRecreateReset.allNativeLanesPass, isFalse);

        final noPostRecreateStablePolls =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              createX13DeadObjectSampleRawMap({
                'timestampPostRecreateStablePolls': 0,
              }),
            );
        expect(
          noPostRecreateStablePolls.timestampStabilizationGatesHeld,
          isFalse,
        );
        expect(noPostRecreateStablePolls.allNativeLanesPass, isFalse);
      },
    );

    test('X13 requires zero frame regressions and zero in-loop polls', () {
      final regression =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX13SampleRawMap({'timestampFrameRegressionCount': 1}),
          );
      expect(regression.timestampStabilizationGatesHeld, isFalse);
      expect(regression.allNativeLanesPass, isFalse);

      final pollInsideLoop =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX13SampleRawMap({'timestampPollInsideWriteLoopCount': 1}),
          );
      expect(pollInsideLoop.timestampStabilizationGatesHeld, isFalse);
      expect(pollInsideLoop.allNativeLanesPass, isFalse);

      final tooManyPolls =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX13SampleRawMap({
              'timestampPassPollCount': 329,
              'timestampPassCount': 328,
            }),
          );
      expect(tooManyPolls.timestampStabilizationGatesHeld, isFalse);
      expect(tooManyPolls.allNativeLanesPass, isFalse);
    });

    test('X13 requires positive stable polls and at least 1 frame advance', () {
      final noStablePolls =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX13SampleRawMap({'timestampStablePollCount': 0}),
          );
      expect(noStablePolls.timestampStabilizationGatesHeld, isFalse);
      expect(noStablePolls.allNativeLanesPass, isFalse);

      final noAdvances =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX13SampleRawMap({'timestampFrameAdvanceCount': 0}),
          );
      expect(noAdvances.timestampStabilizationGatesHeld, isFalse);
      expect(noAdvances.allNativeLanesPass, isFalse);
    });

    test('X13 fail report surfaces failure flags and fail marker', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            createX13SampleRawMap({
              'pass': false,
              'status': 'audio_timestamp_warmup_budget_exceeded',
              'marker': _kTimestampStabilizationFailMarker,
              'failureReason': 'audio_timestamp_warmup_budget_exceeded',
              'lastError': 'audio_timestamp_warmup_budget_exceeded',
              'timestampStabilizedOk': false,
              'timestampStabilizationGatesHeld': false,
            }),
          );
      expect(report.pass, isFalse);
      expect(
        report.marker,
        equals(
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
              .timestampStabilizationFailMarkerConstant,
        ),
      );
      expect(report.timestampStabilizedOk, isFalse);
      expect(report.timestampStabilizationGatesHeld, isFalse);
      expect(
        report.lastError,
        equals('audio_timestamp_warmup_budget_exceeded'),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test(
      'X13 standalone mode sends timestampStabilizationProofEnabled=true only',
      () async {
        Map<String, Object?>? capturedArgs;

        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedArgs = (call.arguments as Map).cast<String, Object?>();
          return createX13SampleRawMap();
        });

        final report =
            await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
              sourcePath: '/tmp/clip_B.mov',
              timestampStabilizationProofEnabled: true,
            );

        expect(capturedArgs?['timestampStabilizationProofEnabled'], isTrue);
        expect(
          capturedArgs?.containsKey('deadObjectRecoveryProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('focusNoisyEventHandoffProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('focusDuckRestoreProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('focusLossPauseResumeProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('permanentFocusLossProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('routeChangeEventHandoffProofEnabled'),
          isFalse,
        );
        expect(capturedArgs?.containsKey('envelopeProofEnabled'), isFalse);
        expect(
          capturedArgs?.containsKey('nonZeroGainSinkProofEnabled'),
          isFalse,
        );
        expect(report.pass, isTrue);
        expect(report.timestampStabilizationProofEnabled, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('X13 + X12 mode sends both timestampStabilizationProofEnabled and '
        'deadObjectRecoveryProofEnabled', () async {
      Map<String, Object?>? capturedArgs;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return createX13DeadObjectSampleRawMap();
      });

      final report =
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: '/tmp/clip_B.mov',
            timestampStabilizationProofEnabled: true,
            deadObjectRecoveryProofEnabled: true,
          );

      expect(capturedArgs?['timestampStabilizationProofEnabled'], isTrue);
      expect(capturedArgs?['deadObjectRecoveryProofEnabled'], isTrue);
      expect(
        capturedArgs?.containsKey('focusNoisyEventHandoffProofEnabled'),
        isFalse,
      );
      expect(
        capturedArgs?.containsKey('focusDuckRestoreProofEnabled'),
        isFalse,
      );
      expect(
        capturedArgs?.containsKey('focusLossPauseResumeProofEnabled'),
        isFalse,
      );
      expect(
        capturedArgs?.containsKey('permanentFocusLossProofEnabled'),
        isFalse,
      );
      expect(
        capturedArgs?.containsKey('routeChangeEventHandoffProofEnabled'),
        isFalse,
      );
      expect(capturedArgs?.containsKey('envelopeProofEnabled'), isFalse);
      expect(capturedArgs?.containsKey('nonZeroGainSinkProofEnabled'), isFalse);
      expect(report.pass, isTrue);
      expect(report.timestampStabilizationProofEnabled, isTrue);
      expect(report.deadObjectRecoveryProofEnabled, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test(
      'default X4 run does NOT send timestampStabilizationProofEnabled',
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
          capturedArgs?.containsKey('timestampStabilizationProofEnabled'),
          isFalse,
        );
      },
    );

    test(
      'X6 and X12 runs do NOT send timestampStabilizationProofEnabled',
      () async {
        Map<String, Object?>? capturedArgs;

        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedArgs = (call.arguments as Map).cast<String, Object?>();
          return _createSampleRawMap();
        });

        await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
          sourcePath: '/tmp/clip_B.mov',
          nonZeroGainSinkProofEnabled: true,
        );
        expect(capturedArgs?['nonZeroGainSinkProofEnabled'], isTrue);
        expect(
          capturedArgs?.containsKey('timestampStabilizationProofEnabled'),
          isFalse,
        );

        await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
          sourcePath: '/tmp/clip_B.mov',
          deadObjectRecoveryProofEnabled: true,
        );
        expect(capturedArgs?['deadObjectRecoveryProofEnabled'], isTrue);
        expect(
          capturedArgs?.containsKey('timestampStabilizationProofEnabled'),
          isFalse,
        );
      },
    );
  });

  group('X14 audible speaker playback mode', () {
    test('default X4 pass report has audibleSpeakerPlaybackProofEnabled=false '
        'and gate vacuously true', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createSampleRawMap(),
          );
      expect(report.audibleSpeakerPlaybackProofEnabled, isFalse);
      expect(report.audibleSpeakerRouteSampleCount, equals(0));
      expect(report.audibleSpeakerRouteSampleOk, isFalse);
      expect(report.audibleSpeakerRouteType, equals(-1));
      expect(report.audibleSpeakerBuiltInSpeakerRouteOk, isFalse);
      expect(report.audibleSpeakerPlaybackGatesHeld, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test(
      'X14 pass sample accepts marker, boundary, and metrics, and passes all gates',
      () {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              _createAudibleSpeakerSampleRawMap(),
            );
        expect(report.marker, equals(_kAudibleSpeakerPlaybackPassMarker));
        expect(
          report.proofBoundary,
          equals(_kAudibleSpeakerPlaybackProofBoundary),
        );
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.nativeProofBoundaryOk, isTrue);
        expect(report.audibleSpeakerPlaybackProofEnabled, isTrue);
        expect(report.audioTrackGain, equals(0.5));
        expect(report.audioTrackNonZeroGainSetOk, isTrue);
        expect(report.audibleSpeakerRouteSampleCount, equals(2));
        expect(report.audibleSpeakerRouteSampleOk, isTrue);
        expect(
          report.audibleSpeakerRouteType,
          equals(
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .builtInSpeakerTypeConstant,
          ),
        );
        expect(report.audibleSpeakerBuiltInSpeakerRouteOk, isTrue);
        expect(report.audibleSpeakerPlaybackGatesHeld, isTrue);
        expect(report.nonZeroGainSinkGatesHeld, isTrue);
        expect(report.sinkWriteAccountingOk, isTrue);
        expect(report.frameAccountingOk, isTrue);
        expect(report.checksumIdentityOk, isTrue);
        expect(report.checksumsMatch, isTrue);
        expect(report.realtimeGatesHeld, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('X14 must carry its own pass marker, not other markers', () {
      for (final wrongMarker in const [
        _kPassMarker,
        _kEnvelopePassMarker,
        _kNonZeroGainPassMarker,
        _kFocusNoisyPassMarker,
        _kFocusDuckRestorePassMarker,
        _kFocusLossPauseResumePassMarker,
        _kPermanentFocusLossPassMarker,
        _kRouteChangeEventHandoffPassMarker,
        _kDeadObjectRecoveryPassMarker,
        _kTimestampStabilizationPassMarker,
      ]) {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              _createAudibleSpeakerSampleRawMap({'marker': wrongMarker}),
            );
        expect(report.allNativeLanesPass, isFalse, reason: wrongMarker);
      }
    });

    test(
      'X14 must carry its own proof boundary, not X4 or X8..X13 boundaries',
      () {
        for (final wrongBoundary in const [
          _kCanonicalProofBoundary,
          _kFocusDuckRestoreProofBoundary,
          _kFocusLossPauseResumeProofBoundary,
          _kPermanentFocusLossProofBoundary,
          _kRouteChangeEventHandoffProofBoundary,
          _kDeadObjectRecoveryProofBoundary,
          _kTimestampStabilizationProofBoundary,
          _kTimestampStabilizationDeadObjectRecoveryProofBoundary,
        ]) {
          final report =
              VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
                _createAudibleSpeakerSampleRawMap({
                  'proofBoundary': wrongBoundary,
                }),
              );
          expect(
            report.hasCanonicalProofBoundary,
            isFalse,
            reason: wrongBoundary,
          );
          expect(report.allNativeLanesPass, isFalse, reason: wrongBoundary);
        }
      },
    );

    test('X14 fails gates when audibleSpeakerRouteSampleCount is 0', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createAudibleSpeakerSampleRawMap({
              'audibleSpeakerRouteSampleCount': 0,
            }),
          );
      expect(report.audibleSpeakerPlaybackGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('X14 fails gates when audibleSpeakerRouteSampleOk is false', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createAudibleSpeakerSampleRawMap({
              'audibleSpeakerRouteSampleOk': false,
            }),
          );
      expect(report.audibleSpeakerPlaybackGatesHeld, isFalse);
      expect(report.allNativeLanesPass, isFalse);
    });

    test(
      'X14 fails gates when audibleSpeakerRouteType is not built-in speaker (2)',
      () {
        for (final wrongType in [-1, 0, 1, 3, 4, 7, 8]) {
          final report =
              VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
                _createAudibleSpeakerSampleRawMap({
                  'audibleSpeakerRouteType': wrongType,
                }),
              );
          expect(
            report.audibleSpeakerPlaybackGatesHeld,
            isFalse,
            reason: 'type $wrongType must fail',
          );
          expect(report.allNativeLanesPass, isFalse);
        }
      },
    );

    test(
      'X14 fails gates when audibleSpeakerBuiltInSpeakerRouteOk is false',
      () {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              _createAudibleSpeakerSampleRawMap({
                'audibleSpeakerBuiltInSpeakerRouteOk': false,
              }),
            );
        expect(report.audibleSpeakerPlaybackGatesHeld, isFalse);
        expect(report.allNativeLanesPass, isFalse);
      },
    );

    test(
      'X14 fails gates when audioTrackNonZeroGainSetOk is false or gain != 0.5',
      () {
        final noGainSet =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              _createAudibleSpeakerSampleRawMap({
                'audioTrackNonZeroGainSetOk': false,
              }),
            );
        expect(noGainSet.audibleSpeakerPlaybackGatesHeld, isFalse);
        expect(noGainSet.allNativeLanesPass, isFalse);

        final wrongGain =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              _createAudibleSpeakerSampleRawMap({'audioTrackGain': 0.1}),
            );
        expect(wrongGain.audibleSpeakerPlaybackGatesHeld, isFalse);
        expect(wrongGain.allNativeLanesPass, isFalse);
      },
    );

    test(
      'X14 fails gates when native audibleSpeakerPlaybackGatesHeld lane is false',
      () {
        final report =
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
              _createAudibleSpeakerSampleRawMap({
                'audibleSpeakerPlaybackGatesHeld': false,
              }),
            );
        expect(report.allNativeLanesPass, isFalse);
      },
    );

    test('X14 fail report surfaces failure flags and fail marker', () {
      final report =
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
            _createAudibleSpeakerSampleRawMap({
              'pass': false,
              'status': 'audible_speaker_route_not_builtin_speaker:3',
              'marker': _kAudibleSpeakerPlaybackFailMarker,
              'failureReason': 'audible_speaker_route_not_builtin_speaker:3',
              'lastError': 'audible_speaker_route_not_builtin_speaker:3',
              'audibleSpeakerBuiltInSpeakerRouteOk': false,
              'audibleSpeakerPlaybackGatesHeld': false,
            }),
          );
      expect(report.pass, isFalse);
      expect(
        report.marker,
        equals(
          VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
              .audibleSpeakerPlaybackFailMarkerConstant,
        ),
      );
      expect(report.audibleSpeakerBuiltInSpeakerRouteOk, isFalse);
      expect(report.audibleSpeakerPlaybackGatesHeld, isFalse);
      expect(
        report.lastError,
        equals('audible_speaker_route_not_builtin_speaker:3'),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test(
      'X14 mode sends only audibleSpeakerPlaybackProofEnabled plus common args, '
      'not focus/duck/pause/timestamp/dead-object flags',
      () async {
        Map<String, Object?>? capturedArgs;

        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedArgs = (call.arguments as Map).cast<String, Object?>();
          return _createAudibleSpeakerSampleRawMap();
        });

        final report =
            await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
              sourcePath: '/tmp/clip_B.mov',
              audibleSpeakerPlaybackProofEnabled: true,
            );

        expect(capturedArgs?['audibleSpeakerPlaybackProofEnabled'], isTrue);
        expect(capturedArgs?['sourcePath'], equals('/tmp/clip_B.mov'));
        expect(capturedArgs?['durationSec'], equals(2.0));
        expect(capturedArgs?['seekTargetSec'], equals(1.30));
        expect(capturedArgs?['preSeekBudgetSec'], equals(1.20));
        expect(capturedArgs?['postSeekBudgetSec'], equals(0.55));
        expect(capturedArgs?['sourceRingCapacityFrames'], equals(8192));
        expect(capturedArgs?['outputRingCapacityFrames'], equals(4096));
        expect(capturedArgs?['maxFramesPerMix'], equals(256));
        expect(capturedArgs?['deadlineMs'], equals(30000));
        expect(capturedArgs?.containsKey('envelopeProofEnabled'), isFalse);
        expect(
          capturedArgs?.containsKey('nonZeroGainSinkProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('focusNoisyEventHandoffProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('focusDuckRestoreProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('focusLossPauseResumeProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('permanentFocusLossProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('routeChangeEventHandoffProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('deadObjectRecoveryProofEnabled'),
          isFalse,
        );
        expect(
          capturedArgs?.containsKey('timestampStabilizationProofEnabled'),
          isFalse,
        );
        expect(report.pass, isTrue);
        expect(report.audibleSpeakerPlaybackProofEnabled, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test(
      'default X4 run does NOT send audibleSpeakerPlaybackProofEnabled',
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
          capturedArgs?.containsKey('audibleSpeakerPlaybackProofEnabled'),
          isFalse,
        );
      },
    );
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
