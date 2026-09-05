// vg_realtime_audio_playback_production_types.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK (Y8a) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-DEAD-OBJECT (Y8b) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SEEK (Y9) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-REPEATED-SEEK (Y10b) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-FOCUS-RESPONSE (Y11b) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-ROUTE-CHANGE (Y12) +
// P4-AUDIO-REALTIME-PLAYBACK-PRESENTATION-CLOCK-QUERY-SURFACE (Y13) +
// P4-AUDIO-REALTIME-PLAYBACK-POSITION-QUERY-LIFECYCLE-CONTRACT (Y14) +
// P4-AUDIO-REALTIME-PLAYBACK-CLOCK-CORRELATION-OBSERVATION (Y15) +
// P4-AUDIO-REALTIME-PLAYBACK-CLOCK-DRIFT-SAMPLE-OWNERSHIP (Y16) +
// P4-AUDIO-REALTIME-PLAYBACK-RING-FRAME-SOURCE-PROOF (Y18b) +
// P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER-RING-FRAME-SOURCE (Y18c) +
// P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER-RING-PAUSE-RESUME (Y19) +
// P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER-RING-SEEK (Y20) +
// P4-AUDIO-REALTIME-PLAYBACK-RING-TRANSPORT-SESSION-INTEGRATION (Y21): Android True-DAG Phase 4
// realtime audio playback production sink, clock, dead-object, forward-seek, repeated-seek, focus response, route-change, presentation-clock, position query lifecycle, clock correlation, drift sample ownership, ring frame source, real-decoder ring frame source, real-decoder ring pause/resume, real-decoder ring forward-seek, and real-decoder ring transport session integration diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimeAudioPlaybackProductionSmoke` MethodChannel route.
// Diagnostic-only - drives the production VanguardRealtimeAudioPlaybackSession
// (real MediaExtractor / MediaCodec -> Y5a external ingest -> Y1 transport ->
// sink-thread-owned non-zero-gain AudioTrack + presentation clock) through twelve
// scenarios, plus the isolated Y18b ring-transport frame-source proof, the
// isolated Y18c real-decoder ring-transport frame-source proof, the
// isolated Y19 real-decoder ring pause/resume proof, the isolated Y20
// real-decoder ring true forward-seek proof, and the Y21 real-decoder ring
// transport session integration proof:
//   1. Playthrough + bounded pause/resume to EOS.
//   2. Mid-playback stop/dispose verifying clean release.
//   3. Synthetic dead-object recovery to EOS.
//   4. Forward mid-stream seek while paused to EOS.
//   5. Repeated forward seek while paused (T1 then T2, third seek rejected) to EOS.
//   6. Backward seek while paused (0 <= T <= H - 2 windows) declared to decoder/sink/clock to EOS, second seek rejected.
//   7. Focus duck, restore, transient pause, auto-resume, and noisy terminal pause.
//   8. Focus permanent loss terminal pause without auto-resume.
//   9. Route change observation without transport mutation (independently bounded; no disconnect posted).
//  10. Route disconnect terminal pause, public resume blocked, and routing teardown (independently bounded, fresh PLAYING session).
//  11. Route disconnect while paused by focus policy: public resume blocked and focus auto-resume blocked.
//  12. Presentation clock query surface with off-thread poller to EOS, clock correlation observation, and post-teardown latched read.
//  13. Ring frame source isolated proof driving production sink to EOS without state machine.
//  14. Real-decoder ring frame source isolated proof driving production sink to EOS without state machine.
//  15. Real-decoder ring pause/resume isolated proof: one owner-thread-executed native pause/resume cycle to EOS with checksum identity.
//  16. Real-decoder ring true forward-seek isolated proof: feed held at H, sink drained to H, seek-parked and flushed, one owner-thread-executed native joint seek to T with both ring providers re-anchored by the worker, drained to the seek-aware EOS with checksum identity over expectedFrames - skipped.
//  17. Real-decoder ring transport session integration proof: session constructed with driverFactory route, runs start, awaitFirstAudio, awaitCompletion to EOS, stop, and dispose through session.
//
// Required proof lanes (87 native lanes plus canonical equals 88 total lanes):
//   1. formatProbeOk: format, duration, channel count, sample rate, and MIME probed successfully
//   2. preRollOk: pre-roll while PREPARED until ring_full or declared end fits
//   3. startOk: session and transport transition to PLAYING accepted cleanly
//   4. nonZeroGainAudioTrackOk: AudioTrack initialized with non-zero gain
//   5. playthroughAccountingOk: playthrough accounting matches declared frame count
//   6. checksumIdentityOk: decoder, transport, and sink checksums maintain identity
//   7. clockAnchoredOk: presentation clock anchored to writer head and monotonic
//   8. clockMonotonicOk: presentation clock values strictly monotonic
//   9. clockEpochBalancedOk: clock epoch balance maintained across pause/resume
//  10. clockPauseFrozenOk: presentation clock remains frozen during bounded pause
//  11. boundedPauseResumeOk: bounded pause and resume cleanly closes/reopens epoch
//  12. stopDisposeOk: stop and dispose mid-playback gracefully transitions state
//  13. decoderCancelledOnStopOk: MediaCodec/MediaExtractor worker joins and releases cleanly
//  14. transportDisposedOk: native transport state machine disposed cleanly
//  15. audioTrackReleasedOnceOk: AudioTrack released exactly once
//  16. threadOwnershipOk: strict thread ownership across decode, transport, and sink
//  17. noFeedbackOk: no audio feedback loop or invalid gain ramp detected
//  18. proofBoundaryOk: proof boundary string matches canonical contract exactly
//  19. syntheticDeadObjectRecoveryOk: armed synthetic dead object recovered cleanly on sink thread
//  20. deadObjectClockEpochRebaseOk: presentation clock epoch rebase bounded and monotonic
//  21. deadObjectRemainderAccountingOk: unwritten remainder frames accounted and played on replacement track
//  22. seekQuiesceAccountingOk: feed held at window-aligned anchor and quiescence accounted
//  23. seekCommandOk: forward seek command issued while paused and generations advanced cleanly
//  24. sinkFlushAtSeekOk: AudioTrack.flush executed once on sink thread at seek
//  25. decoderSeekReanchorOk: decoder reanchored to seek target cleanly on decode thread
//  26. staleGenerationRejectedOk: deliberate stale generation probe rejected before JNI ingest
//  27. seekClockEpochOk: presentation clock epoch opened at seek target with deliberate discontinuity
//  28. postSeekDrainOk: post-seek playback drained cleanly to EOS with total frames accounting
//  29. repeatedSeekCommandOk: repeated forward seek commands (T1 then T2) issued and accepted cleanly
//  30. repeatedSeekCumulativeAccountingOk: cumulative frame accounting across repeated seeks equals expected total
//  31. repeatedSeekThirdRejectOk: third repeated seek call rejected without teardown or state mutation
//  32. backwardSeekAdmissionOk: backward seek armed with target within [0, H - 2 windows]
//  33. backwardSeekQuiesceAccountingOk: feed held at window-aligned anchor and quiescence accounted before backward seek
//  34. backwardSinkFlushAtSeekOk: AudioTrack.flush executed once on sink thread at backward seek
//  35. backwardSeekCommandOk: backward seek command issued while paused and generations advanced cleanly
//  36. backwardDecoderReanchorOk: decoder reanchored backward to seek target cleanly on decode thread
//  37. backwardStaleGenerationRejectedOk: deliberate stale generation probe rejected before JNI ingest on backward seek
//  38. backwardSeekClockEpochRebaseOk: presentation clock epoch rebased backward at target as a declared discontinuity
//  39. backwardPositionQueryRebaseOk: position query rebased to the backward target immediately after seek
//  40. backwardDriftSampleBoundedOk: drift sample counters stayed bounded and consistent across the backward discontinuity
//  41. backwardClockCorrelationOk: presentation clock stayed correlated and consistent with sink timestamps across the backward seek
//  42. backwardPostSeekFrameAccountingOk: post-backward-seek playback drained cleanly to EOS with total frames accounting
//  43. backwardSeekRepeatedRejectOk: second backward seek call rejected without teardown or state mutation
//  44. backwardNoFeedbackOk: backward seek observation without feedback or pacing mutation
//  45. focusSetupOk: focus request and noisy receiver registered, monitor started
//  46. focusDuckRestoreOk: transient duck gain and full restore applied on sink thread
//  47. focusTransientPauseResumeOk: transient loss pauses transport, subsequent gain auto-resumes
//  48. focusNoisyTerminalPauseOk: noisy event triggers terminal pause, subsequent gain ignored
//  49. focusPermanentLossPauseOk: permanent loss triggers terminal pause, subsequent gain ignored
//  50. focusMonitorTeardownOk: focus monitor thread exited/joined and controller released cleanly
//  51. routingSetupOk: routing controller attached and monitor thread started cleanly
//  52. routeChangeObservationOk: route change observed without mutating transport state
//  53. routeDisconnectTerminalPauseOk: route disconnect triggers terminal pause with AudioTrack paused at park
//  54. routeDisconnectResumeBlockedOk: public resume rejected and subsequent focus gain does not auto-resume
//  55. routingMonitorTeardownOk: routing controller released, monitor thread exited and joined cleanly
//  56. currentPositionQuerySurfaceOk: currentPosition queried across thread boundaries without mutation
//  57. currentPositionPollerMonotonicOk: off-thread poller position reads monotonic without regression
//  58. currentPositionReadCounterIsolationOk: currentPosition read counters isolated between writer and other threads
//  59. presentationLagTelemetryOk: presentation lag telemetry captured with valid bounds and samples
//  60. presentationLagBoundedOk: presentation lag samples remain strictly within analytical bounds
//  61. positionAtEosNoRunawayOk: position at EOS non-negative and bounded without runaway
//  62. positionQueryPauseHoldFrozenOk: position query frozen and non-regressing during bounded pause hold
//  63. positionQueryDeadObjectRebaseOk: position query rebased monotonically across dead-object recovery
//  64. positionQuerySeekBaseAdvanceOk: position query advanced at or beyond target after forward seek
//  65. positionQueryRepeatedSeekBaseAdvanceOk: position query advanced across repeated seeks without regression
//  66. positionQueryPostTeardownLatchedOk: position query read post-stop/dispose latched cleanly
//  67. nativeAudioClockSnapshotPublishedOk: native audio clock snapshot published with non-blank state and non-negative positions
//  68. clockCorrelationTelemetryOk: presentation clock snapshot consistent and correlation offset telemetry present
//  69. clockObservationNoFeedbackOk: clock correlation observation executed without feedback or transport mutation
//  70. driftSampleWorkerOwnedOk: drift samples posted on sink worker thread and verified
//  71. driftSampleGenerationPinnedOk: drift sample generation pinned and stale generation rejected
//  72. driftSampleNoFeedbackOk: drift sample observation without feedback or pacing mutation
//  73. clockAuthorityUnchangedOk: clock authority and query surface unchanged
//  74. ringFrameSourceOk: production sink consumes async-runtime multi-source output ring to EOS without state machine
//  75. realDecoderRingFrameSourceOk: production sink consumes real-decoder (MediaExtractor/MediaCodec track0 plus synthetic track1 lockstep) async-runtime output ring to EOS without state machine
//  76. realRingPauseAckOk: native pause acknowledged on the ring owner thread after feed quiesced at a clean boundary and the sink was parked before ring pause
//  77. realRingPauseHoldFrozenOk: paused hold observed frozen with no owner feed step, EOS poll, or drain while paused
//  78. realRingResumeAckOk: native resume acknowledged on the ring owner thread with totals unchanged across the hold and the sink unparked after
//  79. realRingPostResumeChecksumOk: resume drains to EOS with exact frame and checksum identity across the full real-decoder ring pause/resume route
//  80. realRingSeekQuiesceAckOk: feed held at the derived hold frame, sink drained exactly to it, seek-parked and flushed before the ring seek, native quiescence proven snapshot-only
//  81. realRingSeekReanchorOk: one owner-thread-executed native joint seek to a target strictly past the hold, both ring providers re-anchored by the worker at the target, generator/extractor/codec re-anchored, post-seek prefill, output seek ack consumed with zero discard
//  82. realRingSeekPostSeekDrainOk: sink unparked after the ring seek with its epoch at the target and drained to the native seek-aware EOS over exactly the effective frames
//  83. realRingSeekChecksumIdentityOk: exact frame and checksum identity over the effective (expectedFrames - skipped) frames across the full real-decoder ring forward-seek route
//  84. ringSessionStartOk: session and transport transition to PLAYING on driver route accepted cleanly with valid driver geometry
//  85. ringSessionPlaythroughAccountingOk: playthrough accounting matches declared frame count to EOS via session completion
//  86. ringSessionChecksumIdentityOk: ring native output and read checksums match sink checksum across session integration
//  87. ringSessionStopDisposeOk: session stop and dispose cleans up driver and sink cleanly without failure
//  (canonical: aggregate pass evaluation holding across all required lanes)
//
// Honest non-claims (Proof Boundary):
// production_engine_component_diagnostic_route_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_sink_thread_owned_audiotrack_and_presentation_clock_bounded_pause_resume_closes_reopens_clock_epoch_at_last_published_position_synthetic_armed_dead_object_recovered_once_on_sink_thread_same_parameter_audiotrack_epoch_rebase_real_or_repeated_dead_object_fails_closed_one_forward_mid_stream_seek_while_paused_feed_held_at_window_aligned_anchor_quiescent_audiotrack_flush_once_on_sink_thread_before_transport_seek_seek_clock_epoch_based_at_target_deliberate_discontinuity_stale_generation_rejected_before_jni_two_ordered_forward_seeks_and_third_rejected_without_teardown_one_backward_seek_while_paused_declared_to_decoder_sink_clock_production_focus_response_focus_monitor_single_consumer_audiomanager_focus_request_becoming_noisy_receiver_sink_thread_gain_duck_restore_request_ack_transient_pause_auto_resume_user_intent_gated_noisy_terminal_pause_no_auto_resume_permanent_loss_pause_no_auto_resume_production_route_change_response_routing_monitor_single_consumer_audiotrack_routing_listener_attach_detach_route_change_observed_no_transport_mutation_route_disconnect_terminal_pause_no_resume_focus_gain_after_route_disconnect_no_auto_resume_presentation_clock_query_surface_off_thread_current_position_poller_monotonic_current_position_read_counter_isolation_epoch_relative_presentation_lag_bounded_position_at_eos_no_runaway_position_query_lifecycle_pause_seek_dead_object_teardown_native_clock_correlation_observation_no_feedback_native_clock_drift_sample_ownership_generation_pinned_no_feedback_ring_transport_frame_source_seam_production_sink_consumes_async_runtime_multi_source_output_ring_to_eos_without_state_machine_native_eos_drained_observed_by_sink_read_no_owner_pre_drain_real_decoder_ring_frame_source_proof_only_kotlin_owned_mediaextractor_mediacodec_track0_plus_synthetic_track1_lockstep_ingest_pump_to_async_runtime_multi_source_output_ring_ring_owner_thread_services_sink_drains_per_drain_wait_bound_no_private_output_drain_expected_frames_window_aligned_eos_pad_budget_one_second_or_truncate_codec_extractor_released_once_missing_frame_source_fails_before_audiotrack_no_current_position_authority_switch_no_fleet_claim_stop_dispose_release_once_no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_no_feedback_control_loop_no_pacing_correction_no_resampling_no_av_sync_closure_no_real_os_call_bt_route_arbitration_no_acoustic_loudness_snr_claim_no_audio_clock_mutator_changes_no_clock_feedback_no_pacing_feedback_real_decoder_ring_pause_resume_proof_only_one_owner_thread_executed_native_pause_resume_cycle_feed_quiesced_at_clean_boundary_before_sink_park_sink_parked_before_ring_pause_no_feedstep_no_eos_poll_no_native_read_while_paused_resume_drains_to_eos_with_checksum_identity_no_seek_no_flush_no_dead_object_no_feedback_no_pacing_no_resampling_no_current_position_authority_switch_no_av_sync_closure_no_fleet_claim_no_app_no_editor_claim
//
// Honest operational non-claims:
//   - Synthetic recovery is not gapless; up to one AudioTrack client buffer plus
//     one mix window of already-written content may be discarded with the dead
//     instance.
//   - 300 ms publication lag is device observability budget, not latency/SLA.
//   - Checksum identity is over frames handed to write, not frames audibly presented.
//   - Forward seek exercises ONE forward seek while paused; repeated seek exercises
//     two ordered forward seeks while paused and verifies third rejected without teardown.
//   - Backward seek exercises ONE backward seek while paused (0 <= T <= H - 2 windows)
//     declared backward to the decoder, sink, and presentation clock, and verifies a
//     second seek call rejected without teardown; it carries no feedback, pacing,
//     resampling, AV-sync, acoustic, or route-arbitration claim.
//   - Audio focus proof operates on synthetic focus change / becoming noisy seams without
//     requiring real OS phone calls or bluetooth events during headless diagnostic runs.
//   - Route change and route disconnect proof operates on synthetic route change / disconnect seams without
//     requiring real OS bluetooth or headphone events during headless diagnostic runs.
//   - Real-decoder ring frame source (Y18c) proves the production sink fed, via the
//     Y18a frameSource seam, from the async-runtime multi-source native output ring
//     whose track 0 is a real Kotlin-owned MediaExtractor/MediaCodec PCM16 decode and
//     whose track 1 is the deterministic synthetic feed, in lockstep, with neither a
//     stateMachine nor a session nor the production decoder feed involved; it carries
//     no seek, no pause/resume, no drift feedback, no pacing correction, no resampling,
//     no currentPosition authority switch, no A/V sync closure, no cross-device
//     bit-exact decoder claim, and no fleet claim.
//   - Real-decoder ring pause/resume (Y19) proves exactly one owner-thread-executed
//     native Pause/Resume cycle on the Y18c real-decoder ring: feed quiesced at a
//     clean boundary before the sink is parked, the sink parked before the ring is
//     paused, no feedStep/EOS poll/native read while paused, and resume draining to
//     EOS with exact frame and checksum identity; it carries no seek, no flush, no
//     dead object, no drift feedback, no pacing correction, no resampling, no
//     currentPosition authority switch, no A/V sync closure, no fleet claim, and no
//     app/editor claim.
//   - Real-decoder ring forward seek (Y20) proves exactly one owner-thread-executed
//     native joint seek on the Y18c real-decoder ring to a window-aligned target T
//     strictly past the window-aligned hold H: feed held at H, the production sink
//     drained to H, seek-parked and flushed before the ring seek, native quiescence
//     proven snapshot-only, both native ring providers re-anchored once by the
//     worker at T (no provider forward skip, no zero-fill), and every frame and
//     checksum identity asserted over the effective (expectedFrames - skipped)
//     frames; the extractor landing at or before T is reported, never claimed
//     exact. It carries no pause/resume, no dead object, no drift feedback, no
//     pacing correction, no resampling, no currentPosition authority switch, no
//     A/V sync closure, no fleet claim, and no app/editor claim.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimeAudioPlaybackProductionSmokeReport.runRealtimeAudioPlaybackProductionSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
///
/// Honest operational non-claims:
///   - Synthetic recovery is not gapless; up to one AudioTrack client buffer plus
///     one mix window of already-written content may be discarded with the dead
///     instance.
///   - 300 ms publication lag is device observability budget, not latency/SLA.
///   - Checksum identity is over frames handed to write, not frames audibly presented.
@immutable
class VGRealtimeAudioPlaybackProductionSmokeReport {
  const VGRealtimeAudioPlaybackProductionSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.preRollOk,
    required this.startOk,
    required this.nonZeroGainAudioTrackOk,
    required this.playthroughAccountingOk,
    required this.checksumIdentityOk,
    required this.clockAnchoredOk,
    required this.clockMonotonicOk,
    required this.clockEpochBalancedOk,
    required this.clockPauseFrozenOk,
    required this.boundedPauseResumeOk,
    required this.stopDisposeOk,
    required this.decoderCancelledOnStopOk,
    required this.transportDisposedOk,
    required this.audioTrackReleasedOnceOk,
    required this.threadOwnershipOk,
    required this.noFeedbackOk,
    required this.proofBoundaryOk,
    required this.syntheticDeadObjectRecoveryOk,
    required this.deadObjectClockEpochRebaseOk,
    required this.deadObjectRemainderAccountingOk,
    required this.seekQuiesceAccountingOk,
    required this.seekCommandOk,
    required this.sinkFlushAtSeekOk,
    required this.decoderSeekReanchorOk,
    required this.staleGenerationRejectedOk,
    required this.seekClockEpochOk,
    required this.postSeekDrainOk,
    required this.repeatedSeekCommandOk,
    required this.repeatedSeekCumulativeAccountingOk,
    required this.repeatedSeekThirdRejectOk,
    required this.backwardSeekAdmissionOk,
    required this.backwardSeekQuiesceAccountingOk,
    required this.backwardSinkFlushAtSeekOk,
    required this.backwardSeekCommandOk,
    required this.backwardDecoderReanchorOk,
    required this.backwardStaleGenerationRejectedOk,
    required this.backwardSeekClockEpochRebaseOk,
    required this.backwardPositionQueryRebaseOk,
    required this.backwardDriftSampleBoundedOk,
    required this.backwardClockCorrelationOk,
    required this.backwardPostSeekFrameAccountingOk,
    required this.backwardSeekRepeatedRejectOk,
    required this.backwardNoFeedbackOk,
    required this.focusSetupOk,
    required this.focusDuckRestoreOk,
    required this.focusTransientPauseResumeOk,
    required this.focusNoisyTerminalPauseOk,
    required this.focusPermanentLossPauseOk,
    required this.focusMonitorTeardownOk,
    required this.routingSetupOk,
    required this.routeChangeObservationOk,
    required this.routeDisconnectTerminalPauseOk,
    required this.routeDisconnectResumeBlockedOk,
    required this.routingMonitorTeardownOk,
    required this.currentPositionQuerySurfaceOk,
    required this.currentPositionPollerMonotonicOk,
    required this.currentPositionReadCounterIsolationOk,
    required this.presentationLagTelemetryOk,
    required this.presentationLagBoundedOk,
    required this.positionAtEosNoRunawayOk,
    required this.positionQueryPauseHoldFrozenOk,
    required this.positionQueryDeadObjectRebaseOk,
    required this.positionQuerySeekBaseAdvanceOk,
    required this.positionQueryRepeatedSeekBaseAdvanceOk,
    required this.positionQueryPostTeardownLatchedOk,
    required this.nativeAudioClockSnapshotPublishedOk,
    required this.clockCorrelationTelemetryOk,
    required this.clockObservationNoFeedbackOk,
    required this.driftSampleWorkerOwnedOk,
    required this.driftSampleGenerationPinnedOk,
    required this.driftSampleNoFeedbackOk,
    required this.clockAuthorityUnchangedOk,
    required this.ringFrameSourceOk,
    required this.realDecoderRingFrameSourceOk,
    required this.realRingPauseAckOk,
    required this.realRingPauseHoldFrozenOk,
    required this.realRingResumeAckOk,
    required this.realRingPostResumeChecksumOk,
    required this.realRingSeekQuiesceAckOk,
    required this.realRingSeekReanchorOk,
    required this.realRingSeekPostSeekDrainOk,
    required this.realRingSeekChecksumIdentityOk,
    required this.ringSessionStartOk,
    required this.ringSessionPlaythroughAccountingOk,
    required this.ringSessionChecksumIdentityOk,
    required this.ringSessionStopDisposeOk,
    required this.canonical,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
    this.raw = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runRealtimeAudioPlaybackProductionSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'production_engine_component_diagnostic_route_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_sink_thread_owned_audiotrack_and_presentation_clock_bounded_pause_resume_closes_reopens_clock_epoch_at_last_published_position_synthetic_armed_dead_object_recovered_once_on_sink_thread_same_parameter_audiotrack_epoch_rebase_real_or_repeated_dead_object_fails_closed_one_forward_mid_stream_seek_while_paused_feed_held_at_window_aligned_anchor_quiescent_audiotrack_flush_once_on_sink_thread_before_transport_seek_seek_clock_epoch_based_at_target_deliberate_discontinuity_stale_generation_rejected_before_jni_two_ordered_forward_seeks_and_third_rejected_without_teardown_one_backward_seek_while_paused_declared_to_decoder_sink_clock_production_focus_response_focus_monitor_single_consumer_audiomanager_focus_request_becoming_noisy_receiver_sink_thread_gain_duck_restore_request_ack_transient_pause_auto_resume_user_intent_gated_noisy_terminal_pause_no_auto_resume_permanent_loss_pause_no_auto_resume_production_route_change_response_routing_monitor_single_consumer_audiotrack_routing_listener_attach_detach_route_change_observed_no_transport_mutation_route_disconnect_terminal_pause_no_resume_focus_gain_after_route_disconnect_no_auto_resume_presentation_clock_query_surface_off_thread_current_position_poller_monotonic_current_position_read_counter_isolation_epoch_relative_presentation_lag_bounded_position_at_eos_no_runaway_position_query_lifecycle_pause_seek_dead_object_teardown_native_clock_correlation_observation_no_feedback_native_clock_drift_sample_ownership_generation_pinned_no_feedback_ring_transport_frame_source_seam_production_sink_consumes_async_runtime_multi_source_output_ring_to_eos_without_state_machine_native_eos_drained_observed_by_sink_read_no_owner_pre_drain_real_decoder_ring_frame_source_proof_only_kotlin_owned_mediaextractor_mediacodec_track0_plus_synthetic_track1_lockstep_ingest_pump_to_async_runtime_multi_source_output_ring_ring_owner_thread_services_sink_drains_per_drain_wait_bound_no_private_output_drain_expected_frames_window_aligned_eos_pad_budget_one_second_or_truncate_codec_extractor_released_once_missing_frame_source_fails_before_audiotrack_no_current_position_authority_switch_no_fleet_claim_stop_dispose_release_once_no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_no_feedback_control_loop_no_pacing_correction_no_resampling_no_av_sync_closure_no_real_os_call_bt_route_arbitration_no_acoustic_loudness_snr_claim_no_audio_clock_mutator_changes_no_clock_feedback_no_pacing_feedback_real_decoder_ring_pause_resume_proof_only_one_owner_thread_executed_native_pause_resume_cycle_feed_quiesced_at_clean_boundary_before_sink_park_sink_parked_before_ring_pause_no_feedstep_no_eos_poll_no_native_read_while_paused_resume_drains_to_eos_with_checksum_identity_no_seek_no_flush_no_dead_object_no_feedback_no_pacing_no_resampling_no_current_position_authority_switch_no_av_sync_closure_no_fleet_claim_no_app_no_editor_claim';

  /// All required non-canonical native lane keys that must be evaluated and true.
  static const List<String> requiredNonCanonicalLanes = <String>[
    'formatProbeOk',
    'preRollOk',
    'startOk',
    'nonZeroGainAudioTrackOk',
    'playthroughAccountingOk',
    'checksumIdentityOk',
    'clockAnchoredOk',
    'clockMonotonicOk',
    'clockEpochBalancedOk',
    'clockPauseFrozenOk',
    'boundedPauseResumeOk',
    'stopDisposeOk',
    'decoderCancelledOnStopOk',
    'transportDisposedOk',
    'audioTrackReleasedOnceOk',
    'threadOwnershipOk',
    'noFeedbackOk',
    'proofBoundaryOk',
    'syntheticDeadObjectRecoveryOk',
    'deadObjectClockEpochRebaseOk',
    'deadObjectRemainderAccountingOk',
    'seekQuiesceAccountingOk',
    'seekCommandOk',
    'sinkFlushAtSeekOk',
    'decoderSeekReanchorOk',
    'staleGenerationRejectedOk',
    'seekClockEpochOk',
    'postSeekDrainOk',
    'repeatedSeekCommandOk',
    'repeatedSeekCumulativeAccountingOk',
    'repeatedSeekThirdRejectOk',
    'backwardSeekAdmissionOk',
    'backwardSeekQuiesceAccountingOk',
    'backwardSinkFlushAtSeekOk',
    'backwardSeekCommandOk',
    'backwardDecoderReanchorOk',
    'backwardStaleGenerationRejectedOk',
    'backwardSeekClockEpochRebaseOk',
    'backwardPositionQueryRebaseOk',
    'backwardDriftSampleBoundedOk',
    'backwardClockCorrelationOk',
    'backwardPostSeekFrameAccountingOk',
    'backwardSeekRepeatedRejectOk',
    'backwardNoFeedbackOk',
    'focusSetupOk',
    'focusDuckRestoreOk',
    'focusTransientPauseResumeOk',
    'focusNoisyTerminalPauseOk',
    'focusPermanentLossPauseOk',
    'focusMonitorTeardownOk',
    'routingSetupOk',
    'routeChangeObservationOk',
    'routeDisconnectTerminalPauseOk',
    'routeDisconnectResumeBlockedOk',
    'routingMonitorTeardownOk',
    'currentPositionQuerySurfaceOk',
    'currentPositionPollerMonotonicOk',
    'currentPositionReadCounterIsolationOk',
    'presentationLagTelemetryOk',
    'presentationLagBoundedOk',
    'positionAtEosNoRunawayOk',
    'positionQueryPauseHoldFrozenOk',
    'positionQueryDeadObjectRebaseOk',
    'positionQuerySeekBaseAdvanceOk',
    'positionQueryRepeatedSeekBaseAdvanceOk',
    'positionQueryPostTeardownLatchedOk',
    'nativeAudioClockSnapshotPublishedOk',
    'clockCorrelationTelemetryOk',
    'clockObservationNoFeedbackOk',
    'driftSampleWorkerOwnedOk',
    'driftSampleGenerationPinnedOk',
    'driftSampleNoFeedbackOk',
    'clockAuthorityUnchangedOk',
    'ringFrameSourceOk',
    'realDecoderRingFrameSourceOk',
    'realRingPauseAckOk',
    'realRingPauseHoldFrozenOk',
    'realRingResumeAckOk',
    'realRingPostResumeChecksumOk',
    'realRingSeekQuiesceAckOk',
    'realRingSeekReanchorOk',
    'realRingSeekPostSeekDrainOk',
    'realRingSeekChecksumIdentityOk',
    'ringSessionStartOk',
    'ringSessionPlaythroughAccountingOk',
    'ringSessionChecksumIdentityOk',
    'ringSessionStopDisposeOk',
  ];

  /// All required native lane keys including canonical.
  static const List<String> requiredLanes = <String>[
    ...requiredNonCanonicalLanes,
    'canonical',
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// Status string (e.g. 'pass', 'fail', or fail-closed reason token).
  final String status;

  /// Diagnostic marker string.
  final String marker;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// Native proof boundary string.
  final String nativeProofBoundary;

  /// Failure reason token, if any.
  final String failureReason;

  /// Auxiliary execution details or trace breadcrumbs.
  final String details;

  // ---- Required Lanes -----------------------------------------------------

  /// Whether format, duration, channel count, sample rate, and MIME probed successfully.
  final bool formatProbeOk;

  /// Whether pre-roll succeeded while PREPARED.
  final bool preRollOk;

  /// Whether session and transport transition to PLAYING was accepted cleanly.
  final bool startOk;

  /// Whether AudioTrack initialized with non-zero gain.
  final bool nonZeroGainAudioTrackOk;

  /// Whether playthrough accounting matches declared frame count.
  final bool playthroughAccountingOk;

  /// Whether decoder, transport, and sink checksums maintain identity.
  final bool checksumIdentityOk;

  /// Whether presentation clock anchored to writer head and monotonic.
  final bool clockAnchoredOk;

  /// Whether presentation clock values strictly monotonic.
  final bool clockMonotonicOk;

  /// Whether clock epoch balance maintained across pause/resume.
  final bool clockEpochBalancedOk;

  /// Whether presentation clock remains frozen during bounded pause.
  final bool clockPauseFrozenOk;

  /// Whether bounded pause and resume cleanly closes/reopens epoch.
  final bool boundedPauseResumeOk;

  /// Whether stop and dispose mid-playback gracefully transitions state.
  final bool stopDisposeOk;

  /// Whether MediaCodec/MediaExtractor worker joins and releases cleanly on stop.
  final bool decoderCancelledOnStopOk;

  /// Whether native transport state machine disposed cleanly.
  final bool transportDisposedOk;

  /// Whether AudioTrack released exactly once.
  final bool audioTrackReleasedOnceOk;

  /// Whether strict thread ownership across decode, transport, and sink.
  final bool threadOwnershipOk;

  /// Whether no audio feedback loop or invalid gain ramp detected.
  final bool noFeedbackOk;

  /// Whether proof boundary string matches canonical contract exactly.
  final bool proofBoundaryOk;

  /// Whether the armed synthetic dead object was recovered cleanly on sink thread.
  final bool syntheticDeadObjectRecoveryOk;

  /// Whether the presentation clock epoch rebase was bounded and monotonic across dead-object recovery.
  final bool deadObjectClockEpochRebaseOk;

  /// Whether unwritten remainder frames were accounted for and played on replacement AudioTrack.
  final bool deadObjectRemainderAccountingOk;

  /// Whether feed was held at window-aligned anchor and quiescence accounted.
  final bool seekQuiesceAccountingOk;

  /// Whether seek command issued while paused and generations advanced cleanly.
  final bool seekCommandOk;

  /// Whether AudioTrack.flush executed once on sink thread at seek.
  final bool sinkFlushAtSeekOk;

  /// Whether decoder reanchored to seek target cleanly on decode thread.
  final bool decoderSeekReanchorOk;

  /// Whether deliberate stale generation probe was rejected before JNI ingest.
  final bool staleGenerationRejectedOk;

  /// Whether presentation clock epoch was opened at seek target with deliberate discontinuity.
  final bool seekClockEpochOk;

  /// Whether post-seek playback drained cleanly to EOS with total frames accounting.
  final bool postSeekDrainOk;

  /// Whether repeated forward seek commands (T1 then T2) were accepted cleanly.
  final bool repeatedSeekCommandOk;

  /// Whether cumulative frame accounting across repeated seeks equals expected total.
  final bool repeatedSeekCumulativeAccountingOk;

  /// Whether third repeated seek was rejected without teardown or mutation.
  final bool repeatedSeekThirdRejectOk;

  /// Whether the backward seek was armed with target within [0, H - 2 windows].
  final bool backwardSeekAdmissionOk;

  /// Whether feed was held at window-aligned anchor and quiescence accounted before the backward seek.
  final bool backwardSeekQuiesceAccountingOk;

  /// Whether AudioTrack.flush executed once on sink thread at the backward seek.
  final bool backwardSinkFlushAtSeekOk;

  /// Whether the backward seek command was issued while paused and generations advanced cleanly.
  final bool backwardSeekCommandOk;

  /// Whether the decoder reanchored backward to the seek target cleanly on decode thread.
  final bool backwardDecoderReanchorOk;

  /// Whether the deliberate stale generation probe was rejected before JNI ingest on the backward seek.
  final bool backwardStaleGenerationRejectedOk;

  /// Whether the presentation clock epoch was rebased backward at target as a declared discontinuity.
  final bool backwardSeekClockEpochRebaseOk;

  /// Whether the position query rebased to the backward target immediately after seek.
  final bool backwardPositionQueryRebaseOk;

  /// Whether drift sample counters stayed bounded and consistent across the backward discontinuity.
  final bool backwardDriftSampleBoundedOk;

  /// Whether the presentation clock stayed correlated and consistent with sink timestamps across the backward seek.
  final bool backwardClockCorrelationOk;

  /// Whether post-backward-seek playback drained cleanly to EOS with total frames accounting.
  final bool backwardPostSeekFrameAccountingOk;

  /// Whether the second backward seek call was rejected without teardown or mutation.
  final bool backwardSeekRepeatedRejectOk;

  /// Whether the backward seek observation operated without feedback or pacing mutation.
  final bool backwardNoFeedbackOk;

  /// Whether audio focus and noisy monitor setup succeeded.
  final bool focusSetupOk;

  /// Whether transient duck gain change and full gain restore succeeded on sink thread.
  final bool focusDuckRestoreOk;

  /// Whether transient focus loss pause and auto-resume succeeded with user intent gating.
  final bool focusTransientPauseResumeOk;

  /// Whether becoming-noisy triggered terminal pause and rejected subsequent auto-resume.
  final bool focusNoisyTerminalPauseOk;

  /// Whether permanent focus loss triggered terminal pause and rejected subsequent auto-resume.
  final bool focusPermanentLossPauseOk;

  /// Whether audio focus controller released, monitor thread exited and joined cleanly.
  final bool focusMonitorTeardownOk;

  /// Whether audio routing setup and monitor thread start succeeded.
  final bool routingSetupOk;

  /// Whether route change observation succeeded without transport mutation.
  final bool routeChangeObservationOk;

  /// Whether route disconnect triggered terminal pause with AudioTrack paused at park.
  final bool routeDisconnectTerminalPauseOk;

  /// Whether public resume was rejected and subsequent focus gain did not auto-resume.
  final bool routeDisconnectResumeBlockedOk;

  /// Whether routing controller was released and monitor thread exited and joined cleanly.
  final bool routingMonitorTeardownOk;

  /// Whether public current-position query surface returned valid values on any thread.
  final bool currentPositionQuerySurfaceOk;

  /// Whether off-thread poller observed monotonic position reads without regression.
  final bool currentPositionPollerMonotonicOk;

  /// Whether currentPosition read counters are isolated between writer and other threads.
  final bool currentPositionReadCounterIsolationOk;

  /// Whether presentation lag telemetry was captured with valid bounds and samples.
  final bool presentationLagTelemetryOk;

  /// Whether presentation lag samples remained strictly within analytical bounds.
  final bool presentationLagBoundedOk;

  /// Whether position reported at EOS was non-negative and bounded without runaway.
  final bool positionAtEosNoRunawayOk;

  /// Whether position query remained strictly frozen and non-regressing during bounded pause hold.
  final bool positionQueryPauseHoldFrozenOk;

  /// Whether position query rebased monotonically across dead-object recovery and latched post-teardown.
  final bool positionQueryDeadObjectRebaseOk;

  /// Whether position query advanced at or beyond target after forward seek with no regression.
  final bool positionQuerySeekBaseAdvanceOk;

  /// Whether position query advanced at or beyond targets across repeated seeks with third rejected seek not regressing.
  final bool positionQueryRepeatedSeekBaseAdvanceOk;

  /// Whether position query read post-stop/dispose latched cleanly and remained >= final clock envelope.
  final bool positionQueryPostTeardownLatchedOk;

  /// Whether native audio clock snapshot was published with valid state and non-negative positions.
  final bool nativeAudioClockSnapshotPublishedOk;

  /// Whether clock correlation telemetry was captured with consistent presentation clock and offset telemetry.
  final bool clockCorrelationTelemetryOk;

  /// Whether clock correlation observation executed without feedback or transport command mutation.
  final bool clockObservationNoFeedbackOk;

  /// Whether drift samples were posted and recorded on the sink worker thread.
  final bool driftSampleWorkerOwnedOk;

  /// Whether drift sample generation was pinned and stale generation was rejected.
  final bool driftSampleGenerationPinnedOk;

  /// Whether drift sample observation operated without feedback or pacing mutation.
  final bool driftSampleNoFeedbackOk;

  /// Whether presentation clock authority remained unchanged across drift sampling.
  final bool clockAuthorityUnchangedOk;

  /// Whether production sink consumes async-runtime multi-source output ring to EOS without state machine.
  final bool ringFrameSourceOk;

  /// Whether production sink consumes a real-decoder (MediaExtractor/MediaCodec track0 plus synthetic track1 lockstep) async-runtime output ring to EOS without state machine.
  final bool realDecoderRingFrameSourceOk;

  /// Whether native pause was acknowledged on the ring owner thread after feed quiesced at a clean boundary and the sink was parked before ring pause.
  final bool realRingPauseAckOk;

  /// Whether the paused hold was observed frozen with no owner feed step, EOS poll, or drain while paused.
  final bool realRingPauseHoldFrozenOk;

  /// Whether native resume was acknowledged on the ring owner thread with totals unchanged across the hold and the sink unparked after.
  final bool realRingResumeAckOk;

  /// Whether resume drained to EOS with exact frame and checksum identity across the full real-decoder ring pause/resume route.
  final bool realRingPostResumeChecksumOk;

  /// Whether the feed was held at the derived hold frame, the sink drained exactly to it, seek-parked and flushed before the ring seek, and native quiescence was proven snapshot-only.
  final bool realRingSeekQuiesceAckOk;

  /// Whether one owner-thread-executed native joint seek to a target strictly past the hold re-anchored the generator, extractor and codec, prefilled post-seek, and consumed the output seek ack with zero discard.
  final bool realRingSeekReanchorOk;

  /// Whether the sink unparked after the ring seek with its epoch at the target and drained to the native seek-aware EOS over exactly the effective frames.
  final bool realRingSeekPostSeekDrainOk;

  /// Whether exact frame and checksum identity held over the effective (expectedFrames - skipped) frames across the full real-decoder ring forward-seek route.
  final bool realRingSeekChecksumIdentityOk;

  /// Whether session and transport transition to PLAYING on driver route was accepted cleanly with valid driver geometry.
  final bool ringSessionStartOk;

  /// Whether playthrough accounting matched declared frame count to EOS via session completion.
  final bool ringSessionPlaythroughAccountingOk;

  /// Whether ring native output and read checksums matched sink checksum across session integration.
  final bool ringSessionChecksumIdentityOk;

  /// Whether session stop and dispose cleaned up driver and sink cleanly without failure.
  final bool ringSessionStopDisposeOk;

  /// Canonical pass indicator.
  final bool canonical;

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

  /// Raw textual summary returned by native smoke execution.
  final String raw;

  // ---- Getters ------------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary =>
      proofBoundary == proofBoundaryConstant &&
      (nativeProofBoundary.isEmpty ||
          nativeProofBoundary == proofBoundaryConstant);

  /// Whether [marker] matches the canonical pass marker constant.
  bool get hasPassMarker => marker == passMarkerConstant;

  /// Whether [marker] matches the canonical fail marker constant.
  bool get hasFailMarker => marker == failMarkerConstant;

  /// Whether every required non-canonical lane passed.
  bool get allRequiredNonCanonicalLanesPass =>
      formatProbeOk &&
      preRollOk &&
      startOk &&
      nonZeroGainAudioTrackOk &&
      playthroughAccountingOk &&
      checksumIdentityOk &&
      clockAnchoredOk &&
      clockMonotonicOk &&
      clockEpochBalancedOk &&
      clockPauseFrozenOk &&
      boundedPauseResumeOk &&
      stopDisposeOk &&
      decoderCancelledOnStopOk &&
      transportDisposedOk &&
      audioTrackReleasedOnceOk &&
      threadOwnershipOk &&
      noFeedbackOk &&
      proofBoundaryOk &&
      syntheticDeadObjectRecoveryOk &&
      deadObjectClockEpochRebaseOk &&
      deadObjectRemainderAccountingOk &&
      seekQuiesceAccountingOk &&
      seekCommandOk &&
      sinkFlushAtSeekOk &&
      decoderSeekReanchorOk &&
      staleGenerationRejectedOk &&
      seekClockEpochOk &&
      postSeekDrainOk &&
      repeatedSeekCommandOk &&
      repeatedSeekCumulativeAccountingOk &&
      repeatedSeekThirdRejectOk &&
      backwardSeekAdmissionOk &&
      backwardSeekQuiesceAccountingOk &&
      backwardSinkFlushAtSeekOk &&
      backwardSeekCommandOk &&
      backwardDecoderReanchorOk &&
      backwardStaleGenerationRejectedOk &&
      backwardSeekClockEpochRebaseOk &&
      backwardPositionQueryRebaseOk &&
      backwardDriftSampleBoundedOk &&
      backwardClockCorrelationOk &&
      backwardPostSeekFrameAccountingOk &&
      backwardSeekRepeatedRejectOk &&
      backwardNoFeedbackOk &&
      focusSetupOk &&
      focusDuckRestoreOk &&
      focusTransientPauseResumeOk &&
      focusNoisyTerminalPauseOk &&
      focusPermanentLossPauseOk &&
      focusMonitorTeardownOk &&
      routingSetupOk &&
      routeChangeObservationOk &&
      routeDisconnectTerminalPauseOk &&
      routeDisconnectResumeBlockedOk &&
      routingMonitorTeardownOk &&
      currentPositionQuerySurfaceOk &&
      currentPositionPollerMonotonicOk &&
      currentPositionReadCounterIsolationOk &&
      presentationLagTelemetryOk &&
      presentationLagBoundedOk &&
      positionAtEosNoRunawayOk &&
      positionQueryPauseHoldFrozenOk &&
      positionQueryDeadObjectRebaseOk &&
      positionQuerySeekBaseAdvanceOk &&
      positionQueryRepeatedSeekBaseAdvanceOk &&
      positionQueryPostTeardownLatchedOk &&
      nativeAudioClockSnapshotPublishedOk &&
      clockCorrelationTelemetryOk &&
      clockObservationNoFeedbackOk &&
      driftSampleWorkerOwnedOk &&
      driftSampleGenerationPinnedOk &&
      driftSampleNoFeedbackOk &&
      clockAuthorityUnchangedOk &&
      ringFrameSourceOk &&
      realDecoderRingFrameSourceOk &&
      realRingPauseAckOk &&
      realRingPauseHoldFrozenOk &&
      realRingResumeAckOk &&
      realRingPostResumeChecksumOk &&
      realRingSeekQuiesceAckOk &&
      realRingSeekReanchorOk &&
      realRingSeekPostSeekDrainOk &&
      realRingSeekChecksumIdentityOk &&
      ringSessionStartOk &&
      ringSessionPlaythroughAccountingOk &&
      ringSessionChecksumIdentityOk &&
      ringSessionStopDisposeOk;

  /// Whether this report meets all verification criteria for a passing smoke run.
  bool get isVerifiedPass =>
      pass &&
      status.trim().toLowerCase() == 'pass' &&
      hasPassMarker &&
      hasCanonicalProofBoundary &&
      canonical &&
      allRequiredNonCanonicalLanesPass &&
      failureReason.isEmpty &&
      (lastError.isEmpty || lastError == 'none' || lastError == 'null');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealtimeAudioPlaybackProductionSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGRealtimeAudioPlaybackProductionSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        nativeProofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        formatProbeOk: false,
        preRollOk: false,
        startOk: false,
        nonZeroGainAudioTrackOk: false,
        playthroughAccountingOk: false,
        checksumIdentityOk: false,
        clockAnchoredOk: false,
        clockMonotonicOk: false,
        clockEpochBalancedOk: false,
        clockPauseFrozenOk: false,
        boundedPauseResumeOk: false,
        stopDisposeOk: false,
        decoderCancelledOnStopOk: false,
        transportDisposedOk: false,
        audioTrackReleasedOnceOk: false,
        threadOwnershipOk: false,
        noFeedbackOk: false,
        proofBoundaryOk: false,
        syntheticDeadObjectRecoveryOk: false,
        deadObjectClockEpochRebaseOk: false,
        deadObjectRemainderAccountingOk: false,
        seekQuiesceAccountingOk: false,
        seekCommandOk: false,
        sinkFlushAtSeekOk: false,
        decoderSeekReanchorOk: false,
        staleGenerationRejectedOk: false,
        seekClockEpochOk: false,
        postSeekDrainOk: false,
        repeatedSeekCommandOk: false,
        repeatedSeekCumulativeAccountingOk: false,
        repeatedSeekThirdRejectOk: false,
        backwardSeekAdmissionOk: false,
        backwardSeekQuiesceAccountingOk: false,
        backwardSinkFlushAtSeekOk: false,
        backwardSeekCommandOk: false,
        backwardDecoderReanchorOk: false,
        backwardStaleGenerationRejectedOk: false,
        backwardSeekClockEpochRebaseOk: false,
        backwardPositionQueryRebaseOk: false,
        backwardDriftSampleBoundedOk: false,
        backwardClockCorrelationOk: false,
        backwardPostSeekFrameAccountingOk: false,
        backwardSeekRepeatedRejectOk: false,
        backwardNoFeedbackOk: false,
        focusSetupOk: false,
        focusDuckRestoreOk: false,
        focusTransientPauseResumeOk: false,
        focusNoisyTerminalPauseOk: false,
        focusPermanentLossPauseOk: false,
        focusMonitorTeardownOk: false,
        routingSetupOk: false,
        routeChangeObservationOk: false,
        routeDisconnectTerminalPauseOk: false,
        routeDisconnectResumeBlockedOk: false,
        routingMonitorTeardownOk: false,
        currentPositionQuerySurfaceOk: false,
        currentPositionPollerMonotonicOk: false,
        currentPositionReadCounterIsolationOk: false,
        presentationLagTelemetryOk: false,
        presentationLagBoundedOk: false,
        positionAtEosNoRunawayOk: false,
        positionQueryPauseHoldFrozenOk: false,
        positionQueryDeadObjectRebaseOk: false,
        positionQuerySeekBaseAdvanceOk: false,
        positionQueryRepeatedSeekBaseAdvanceOk: false,
        positionQueryPostTeardownLatchedOk: false,
        nativeAudioClockSnapshotPublishedOk: false,
        clockCorrelationTelemetryOk: false,
        clockObservationNoFeedbackOk: false,
        driftSampleWorkerOwnedOk: false,
        driftSampleGenerationPinnedOk: false,
        driftSampleNoFeedbackOk: false,
        clockAuthorityUnchangedOk: false,
        ringFrameSourceOk: false,
        realDecoderRingFrameSourceOk: false,
        realRingPauseAckOk: false,
        realRingPauseHoldFrozenOk: false,
        realRingResumeAckOk: false,
        realRingPostResumeChecksumOk: false,
        realRingSeekQuiesceAckOk: false,
        realRingSeekReanchorOk: false,
        realRingSeekPostSeekDrainOk: false,
        realRingSeekChecksumIdentityOk: false,
        ringSessionStartOk: false,
        ringSessionPlaythroughAccountingOk: false,
        ringSessionChecksumIdentityOk: false,
        ringSessionStopDisposeOk: false,
        canonical: false,
        lanes: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        lastError: 'native_result_not_a_map',
        raw:
            'pass=false;status=fail;marker=$failMarkerConstant;reason=native_result_not_a_map',
      );
    }

    final lanesRaw = raw['lanes'];
    final parsedLanes = <String, Object?>{};
    if (lanesRaw is Map) {
      for (final entry in lanesRaw.entries) {
        final k = entry.key?.toString();
        if (k != null) {
          parsedLanes[k] = entry.value;
        }
      }
    }

    final metricsRaw = raw['metrics'];
    final parsedMetrics = <String, Object?>{};
    if (metricsRaw is Map) {
      for (final entry in metricsRaw.entries) {
        final k = entry.key?.toString();
        if (k != null) {
          parsedMetrics[k] = entry.value;
        }
      }
    }

    bool? parseBoolStrict(String key) {
      final v = parsedLanes[key] ?? raw[key] ?? parsedMetrics[key];
      if (v is bool) return v;
      if (v is String) {
        final lower = v.trim().toLowerCase();
        if (lower == 'true' ||
            lower == 'pass' ||
            lower == 'ok' ||
            lower == 'success') {
          return true;
        }
        if (lower == 'false' || lower == 'fail') {
          return false;
        }
      }
      return null;
    }

    bool parseBool(String key, [bool defaultValue = false]) {
      return parseBoolStrict(key) ?? defaultValue;
    }

    String parseString(String key, [String defaultValue = '']) {
      final v = raw[key] ?? parsedMetrics[key];
      return v?.toString() ?? defaultValue;
    }

    final rawPass = parseBool('pass');
    final rawStatus = parseString('status', rawPass ? 'pass' : 'fail');
    final rawMarker = parseString(
      'marker',
      rawPass ? passMarkerConstant : failMarkerConstant,
    );
    final proofBoundary = parseString('proofBoundary');
    final nativeProofBoundary = parseString(
      'nativeProofBoundary',
      proofBoundary,
    );
    final failureReason = parseString('failureReason');
    final details = parseString('details');
    final rawString = parseString(
      'raw',
      'pass=$rawPass;status=$rawStatus;marker=$rawMarker',
    );

    final missingLanes = <String>[];
    for (final laneKey in requiredLanes) {
      if (parseBoolStrict(laneKey) == null) {
        missingLanes.add(laneKey);
      }
    }

    final formatProbeOk = parseBool('formatProbeOk');
    final preRollOk = parseBool('preRollOk');
    final startOk = parseBool('startOk');
    final nonZeroGainAudioTrackOk = parseBool('nonZeroGainAudioTrackOk');
    final playthroughAccountingOk = parseBool('playthroughAccountingOk');
    final checksumIdentityOk = parseBool('checksumIdentityOk');
    final clockAnchoredOk = parseBool('clockAnchoredOk');
    final clockMonotonicOk = parseBool('clockMonotonicOk');
    final clockEpochBalancedOk = parseBool('clockEpochBalancedOk');
    final clockPauseFrozenOk = parseBool('clockPauseFrozenOk');
    final boundedPauseResumeOk = parseBool('boundedPauseResumeOk');
    final stopDisposeOk = parseBool('stopDisposeOk');
    final decoderCancelledOnStopOk = parseBool('decoderCancelledOnStopOk');
    final transportDisposedOk = parseBool('transportDisposedOk');
    final audioTrackReleasedOnceOk = parseBool('audioTrackReleasedOnceOk');
    final threadOwnershipOk = parseBool('threadOwnershipOk');
    final noFeedbackOk = parseBool('noFeedbackOk');
    final proofBoundaryOk = parseBool('proofBoundaryOk');
    final syntheticDeadObjectRecoveryOk = parseBool(
      'syntheticDeadObjectRecoveryOk',
    );
    final deadObjectClockEpochRebaseOk = parseBool(
      'deadObjectClockEpochRebaseOk',
    );
    final deadObjectRemainderAccountingOk = parseBool(
      'deadObjectRemainderAccountingOk',
    );
    final seekQuiesceAccountingOk = parseBool('seekQuiesceAccountingOk');
    final seekCommandOk = parseBool('seekCommandOk');
    final sinkFlushAtSeekOk = parseBool('sinkFlushAtSeekOk');
    final decoderSeekReanchorOk = parseBool('decoderSeekReanchorOk');
    final staleGenerationRejectedOk = parseBool('staleGenerationRejectedOk');
    final seekClockEpochOk = parseBool('seekClockEpochOk');
    final postSeekDrainOk = parseBool('postSeekDrainOk');
    final repeatedSeekCommandOk = parseBool('repeatedSeekCommandOk');
    final repeatedSeekCumulativeAccountingOk = parseBool(
      'repeatedSeekCumulativeAccountingOk',
    );
    final repeatedSeekThirdRejectOk = parseBool('repeatedSeekThirdRejectOk');
    final backwardSeekAdmissionOk = parseBool('backwardSeekAdmissionOk');
    final backwardSeekQuiesceAccountingOk = parseBool(
      'backwardSeekQuiesceAccountingOk',
    );
    final backwardSinkFlushAtSeekOk = parseBool('backwardSinkFlushAtSeekOk');
    final backwardSeekCommandOk = parseBool('backwardSeekCommandOk');
    final backwardDecoderReanchorOk = parseBool('backwardDecoderReanchorOk');
    final backwardStaleGenerationRejectedOk = parseBool(
      'backwardStaleGenerationRejectedOk',
    );
    final backwardSeekClockEpochRebaseOk = parseBool(
      'backwardSeekClockEpochRebaseOk',
    );
    final backwardPositionQueryRebaseOk = parseBool(
      'backwardPositionQueryRebaseOk',
    );
    final backwardDriftSampleBoundedOk = parseBool(
      'backwardDriftSampleBoundedOk',
    );
    final backwardClockCorrelationOk = parseBool('backwardClockCorrelationOk');
    final backwardPostSeekFrameAccountingOk = parseBool(
      'backwardPostSeekFrameAccountingOk',
    );
    final backwardSeekRepeatedRejectOk = parseBool(
      'backwardSeekRepeatedRejectOk',
    );
    final backwardNoFeedbackOk = parseBool('backwardNoFeedbackOk');
    final focusSetupOk = parseBool('focusSetupOk');
    final focusDuckRestoreOk = parseBool('focusDuckRestoreOk');
    final focusTransientPauseResumeOk = parseBool(
      'focusTransientPauseResumeOk',
    );
    final focusNoisyTerminalPauseOk = parseBool('focusNoisyTerminalPauseOk');
    final focusPermanentLossPauseOk = parseBool('focusPermanentLossPauseOk');
    final focusMonitorTeardownOk = parseBool('focusMonitorTeardownOk');
    final routingSetupOk = parseBool('routingSetupOk');
    final routeChangeObservationOk = parseBool('routeChangeObservationOk');
    final routeDisconnectTerminalPauseOk = parseBool(
      'routeDisconnectTerminalPauseOk',
    );
    final routeDisconnectResumeBlockedOk = parseBool(
      'routeDisconnectResumeBlockedOk',
    );
    final routingMonitorTeardownOk = parseBool('routingMonitorTeardownOk');
    final currentPositionQuerySurfaceOk = parseBool(
      'currentPositionQuerySurfaceOk',
    );
    final currentPositionPollerMonotonicOk = parseBool(
      'currentPositionPollerMonotonicOk',
    );
    final currentPositionReadCounterIsolationOk = parseBool(
      'currentPositionReadCounterIsolationOk',
    );
    final presentationLagTelemetryOk = parseBool('presentationLagTelemetryOk');
    final presentationLagBoundedOk = parseBool('presentationLagBoundedOk');
    final positionAtEosNoRunawayOk = parseBool('positionAtEosNoRunawayOk');
    final positionQueryPauseHoldFrozenOk = parseBool(
      'positionQueryPauseHoldFrozenOk',
    );
    final positionQueryDeadObjectRebaseOk = parseBool(
      'positionQueryDeadObjectRebaseOk',
    );
    final positionQuerySeekBaseAdvanceOk = parseBool(
      'positionQuerySeekBaseAdvanceOk',
    );
    final positionQueryRepeatedSeekBaseAdvanceOk = parseBool(
      'positionQueryRepeatedSeekBaseAdvanceOk',
    );
    final positionQueryPostTeardownLatchedOk = parseBool(
      'positionQueryPostTeardownLatchedOk',
    );
    final nativeAudioClockSnapshotPublishedOk = parseBool(
      'nativeAudioClockSnapshotPublishedOk',
    );
    final clockCorrelationTelemetryOk = parseBool(
      'clockCorrelationTelemetryOk',
    );
    final clockObservationNoFeedbackOk = parseBool(
      'clockObservationNoFeedbackOk',
    );
    final driftSampleWorkerOwnedOk = parseBool('driftSampleWorkerOwnedOk');
    final driftSampleGenerationPinnedOk = parseBool(
      'driftSampleGenerationPinnedOk',
    );
    final driftSampleNoFeedbackOk = parseBool('driftSampleNoFeedbackOk');
    final clockAuthorityUnchangedOk = parseBool('clockAuthorityUnchangedOk');
    final ringFrameSourceOk = parseBool('ringFrameSourceOk');
    final realDecoderRingFrameSourceOk = parseBool(
      'realDecoderRingFrameSourceOk',
    );
    final realRingPauseAckOk = parseBool('realRingPauseAckOk');
    final realRingPauseHoldFrozenOk = parseBool('realRingPauseHoldFrozenOk');
    final realRingResumeAckOk = parseBool('realRingResumeAckOk');
    final realRingPostResumeChecksumOk = parseBool(
      'realRingPostResumeChecksumOk',
    );
    final realRingSeekQuiesceAckOk = parseBool('realRingSeekQuiesceAckOk');
    final realRingSeekReanchorOk = parseBool('realRingSeekReanchorOk');
    final realRingSeekPostSeekDrainOk = parseBool(
      'realRingSeekPostSeekDrainOk',
    );
    final realRingSeekChecksumIdentityOk = parseBool(
      'realRingSeekChecksumIdentityOk',
    );
    final ringSessionStartOk = parseBool('ringSessionStartOk');
    final ringSessionPlaythroughAccountingOk = parseBool(
      'ringSessionPlaythroughAccountingOk',
    );
    final ringSessionChecksumIdentityOk = parseBool(
      'ringSessionChecksumIdentityOk',
    );
    final ringSessionStopDisposeOk = parseBool('ringSessionStopDisposeOk');
    final canonical = parseBool('canonical', rawPass && missingLanes.isEmpty);

    final hasValidProofBoundary =
        proofBoundary == proofBoundaryConstant &&
        (nativeProofBoundary.isEmpty ||
            nativeProofBoundary == proofBoundaryConstant);
    final hasValidPassMarker = rawMarker == passMarkerConstant;

    final allRequiredNonCanonicalLanesTrue =
        formatProbeOk &&
        preRollOk &&
        startOk &&
        nonZeroGainAudioTrackOk &&
        playthroughAccountingOk &&
        checksumIdentityOk &&
        clockAnchoredOk &&
        clockMonotonicOk &&
        clockEpochBalancedOk &&
        clockPauseFrozenOk &&
        boundedPauseResumeOk &&
        stopDisposeOk &&
        decoderCancelledOnStopOk &&
        transportDisposedOk &&
        audioTrackReleasedOnceOk &&
        threadOwnershipOk &&
        noFeedbackOk &&
        proofBoundaryOk &&
        syntheticDeadObjectRecoveryOk &&
        deadObjectClockEpochRebaseOk &&
        deadObjectRemainderAccountingOk &&
        seekQuiesceAccountingOk &&
        seekCommandOk &&
        sinkFlushAtSeekOk &&
        decoderSeekReanchorOk &&
        staleGenerationRejectedOk &&
        seekClockEpochOk &&
        postSeekDrainOk &&
        repeatedSeekCommandOk &&
        repeatedSeekCumulativeAccountingOk &&
        repeatedSeekThirdRejectOk &&
        backwardSeekAdmissionOk &&
        backwardSeekQuiesceAccountingOk &&
        backwardSinkFlushAtSeekOk &&
        backwardSeekCommandOk &&
        backwardDecoderReanchorOk &&
        backwardStaleGenerationRejectedOk &&
        backwardSeekClockEpochRebaseOk &&
        backwardPositionQueryRebaseOk &&
        backwardDriftSampleBoundedOk &&
        backwardClockCorrelationOk &&
        backwardPostSeekFrameAccountingOk &&
        backwardSeekRepeatedRejectOk &&
        backwardNoFeedbackOk &&
        focusSetupOk &&
        focusDuckRestoreOk &&
        focusTransientPauseResumeOk &&
        focusNoisyTerminalPauseOk &&
        focusPermanentLossPauseOk &&
        focusMonitorTeardownOk &&
        routingSetupOk &&
        routeChangeObservationOk &&
        routeDisconnectTerminalPauseOk &&
        routeDisconnectResumeBlockedOk &&
        routingMonitorTeardownOk &&
        currentPositionQuerySurfaceOk &&
        currentPositionPollerMonotonicOk &&
        currentPositionReadCounterIsolationOk &&
        presentationLagTelemetryOk &&
        presentationLagBoundedOk &&
        positionAtEosNoRunawayOk &&
        positionQueryPauseHoldFrozenOk &&
        positionQueryDeadObjectRebaseOk &&
        positionQuerySeekBaseAdvanceOk &&
        positionQueryRepeatedSeekBaseAdvanceOk &&
        positionQueryPostTeardownLatchedOk &&
        nativeAudioClockSnapshotPublishedOk &&
        clockCorrelationTelemetryOk &&
        clockObservationNoFeedbackOk &&
        driftSampleWorkerOwnedOk &&
        driftSampleGenerationPinnedOk &&
        driftSampleNoFeedbackOk &&
        clockAuthorityUnchangedOk &&
        ringFrameSourceOk &&
        realDecoderRingFrameSourceOk &&
        realRingPauseAckOk &&
        realRingPauseHoldFrozenOk &&
        realRingResumeAckOk &&
        realRingPostResumeChecksumOk &&
        realRingSeekQuiesceAckOk &&
        realRingSeekReanchorOk &&
        realRingSeekPostSeekDrainOk &&
        realRingSeekChecksumIdentityOk &&
        ringSessionStartOk &&
        ringSessionPlaythroughAccountingOk &&
        ringSessionChecksumIdentityOk &&
        ringSessionStopDisposeOk;

    final allRequiredLanesPresent = missingLanes.isEmpty;
    final explicitLastError = parseString('lastError');
    final hasNoLastError =
        explicitLastError.isEmpty ||
        explicitLastError == 'none' ||
        explicitLastError == 'null';
    final hasNoFailureReason = failureReason.isEmpty;

    final computedPass =
        rawPass &&
        rawStatus.trim().toLowerCase() == 'pass' &&
        hasValidPassMarker &&
        hasValidProofBoundary &&
        allRequiredLanesPresent &&
        allRequiredNonCanonicalLanesTrue &&
        canonical &&
        hasNoLastError &&
        hasNoFailureReason;

    final String finalStatus;
    final String finalMarker;
    final String finalLastError;

    if (computedPass) {
      finalStatus = rawStatus;
      finalMarker = passMarkerConstant;
      finalLastError = '';
    } else {
      finalMarker = (rawMarker == passMarkerConstant)
          ? failMarkerConstant
          : (rawMarker.isNotEmpty ? rawMarker : failMarkerConstant);
      if (failureReason.isNotEmpty) {
        finalLastError = failureReason;
        finalStatus = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      } else if (!hasNoLastError) {
        finalLastError = explicitLastError;
        finalStatus = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      } else if (!hasValidProofBoundary) {
        finalLastError = 'proof_boundary_mismatch';
        finalStatus = 'proof_boundary_mismatch';
      } else if (!hasValidPassMarker) {
        finalLastError = 'marker_mismatch';
        finalStatus = 'marker_mismatch';
      } else if (!allRequiredLanesPresent) {
        finalLastError = 'missing_lane_${missingLanes.first}';
        finalStatus = 'missing_lane';
      } else if (!allRequiredNonCanonicalLanesTrue) {
        finalLastError = 'lane_failed';
        finalStatus = 'lane_failed';
      } else if (!canonical) {
        finalLastError = 'canonical_failed';
        finalStatus = 'canonical_failed';
      } else {
        finalLastError = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
        finalStatus = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      }
    }

    final finalLanes = <String, Object?>{
      'formatProbeOk': formatProbeOk,
      'preRollOk': preRollOk,
      'startOk': startOk,
      'nonZeroGainAudioTrackOk': nonZeroGainAudioTrackOk,
      'playthroughAccountingOk': playthroughAccountingOk,
      'checksumIdentityOk': checksumIdentityOk,
      'clockAnchoredOk': clockAnchoredOk,
      'clockMonotonicOk': clockMonotonicOk,
      'clockEpochBalancedOk': clockEpochBalancedOk,
      'clockPauseFrozenOk': clockPauseFrozenOk,
      'boundedPauseResumeOk': boundedPauseResumeOk,
      'stopDisposeOk': stopDisposeOk,
      'decoderCancelledOnStopOk': decoderCancelledOnStopOk,
      'transportDisposedOk': transportDisposedOk,
      'audioTrackReleasedOnceOk': audioTrackReleasedOnceOk,
      'threadOwnershipOk': threadOwnershipOk,
      'noFeedbackOk': noFeedbackOk,
      'proofBoundaryOk': proofBoundaryOk,
      'syntheticDeadObjectRecoveryOk': syntheticDeadObjectRecoveryOk,
      'deadObjectClockEpochRebaseOk': deadObjectClockEpochRebaseOk,
      'deadObjectRemainderAccountingOk': deadObjectRemainderAccountingOk,
      'seekQuiesceAccountingOk': seekQuiesceAccountingOk,
      'seekCommandOk': seekCommandOk,
      'sinkFlushAtSeekOk': sinkFlushAtSeekOk,
      'decoderSeekReanchorOk': decoderSeekReanchorOk,
      'staleGenerationRejectedOk': staleGenerationRejectedOk,
      'seekClockEpochOk': seekClockEpochOk,
      'postSeekDrainOk': postSeekDrainOk,
      'repeatedSeekCommandOk': repeatedSeekCommandOk,
      'repeatedSeekCumulativeAccountingOk': repeatedSeekCumulativeAccountingOk,
      'repeatedSeekThirdRejectOk': repeatedSeekThirdRejectOk,
      'backwardSeekAdmissionOk': backwardSeekAdmissionOk,
      'backwardSeekQuiesceAccountingOk': backwardSeekQuiesceAccountingOk,
      'backwardSinkFlushAtSeekOk': backwardSinkFlushAtSeekOk,
      'backwardSeekCommandOk': backwardSeekCommandOk,
      'backwardDecoderReanchorOk': backwardDecoderReanchorOk,
      'backwardStaleGenerationRejectedOk': backwardStaleGenerationRejectedOk,
      'backwardSeekClockEpochRebaseOk': backwardSeekClockEpochRebaseOk,
      'backwardPositionQueryRebaseOk': backwardPositionQueryRebaseOk,
      'backwardDriftSampleBoundedOk': backwardDriftSampleBoundedOk,
      'backwardClockCorrelationOk': backwardClockCorrelationOk,
      'backwardPostSeekFrameAccountingOk': backwardPostSeekFrameAccountingOk,
      'backwardSeekRepeatedRejectOk': backwardSeekRepeatedRejectOk,
      'backwardNoFeedbackOk': backwardNoFeedbackOk,
      'focusSetupOk': focusSetupOk,
      'focusDuckRestoreOk': focusDuckRestoreOk,
      'focusTransientPauseResumeOk': focusTransientPauseResumeOk,
      'focusNoisyTerminalPauseOk': focusNoisyTerminalPauseOk,
      'focusPermanentLossPauseOk': focusPermanentLossPauseOk,
      'focusMonitorTeardownOk': focusMonitorTeardownOk,
      'routingSetupOk': routingSetupOk,
      'routeChangeObservationOk': routeChangeObservationOk,
      'routeDisconnectTerminalPauseOk': routeDisconnectTerminalPauseOk,
      'routeDisconnectResumeBlockedOk': routeDisconnectResumeBlockedOk,
      'routingMonitorTeardownOk': routingMonitorTeardownOk,
      'currentPositionQuerySurfaceOk': currentPositionQuerySurfaceOk,
      'currentPositionPollerMonotonicOk': currentPositionPollerMonotonicOk,
      'currentPositionReadCounterIsolationOk':
          currentPositionReadCounterIsolationOk,
      'presentationLagTelemetryOk': presentationLagTelemetryOk,
      'presentationLagBoundedOk': presentationLagBoundedOk,
      'positionAtEosNoRunawayOk': positionAtEosNoRunawayOk,
      'positionQueryPauseHoldFrozenOk': positionQueryPauseHoldFrozenOk,
      'positionQueryDeadObjectRebaseOk': positionQueryDeadObjectRebaseOk,
      'positionQuerySeekBaseAdvanceOk': positionQuerySeekBaseAdvanceOk,
      'positionQueryRepeatedSeekBaseAdvanceOk':
          positionQueryRepeatedSeekBaseAdvanceOk,
      'positionQueryPostTeardownLatchedOk': positionQueryPostTeardownLatchedOk,
      'nativeAudioClockSnapshotPublishedOk':
          nativeAudioClockSnapshotPublishedOk,
      'clockCorrelationTelemetryOk': clockCorrelationTelemetryOk,
      'clockObservationNoFeedbackOk': clockObservationNoFeedbackOk,
      'driftSampleWorkerOwnedOk': driftSampleWorkerOwnedOk,
      'driftSampleGenerationPinnedOk': driftSampleGenerationPinnedOk,
      'driftSampleNoFeedbackOk': driftSampleNoFeedbackOk,
      'clockAuthorityUnchangedOk': clockAuthorityUnchangedOk,
      'ringFrameSourceOk': ringFrameSourceOk,
      'realDecoderRingFrameSourceOk': realDecoderRingFrameSourceOk,
      'realRingPauseAckOk': realRingPauseAckOk,
      'realRingPauseHoldFrozenOk': realRingPauseHoldFrozenOk,
      'realRingResumeAckOk': realRingResumeAckOk,
      'realRingPostResumeChecksumOk': realRingPostResumeChecksumOk,
      'realRingSeekQuiesceAckOk': realRingSeekQuiesceAckOk,
      'realRingSeekReanchorOk': realRingSeekReanchorOk,
      'realRingSeekPostSeekDrainOk': realRingSeekPostSeekDrainOk,
      'realRingSeekChecksumIdentityOk': realRingSeekChecksumIdentityOk,
      'ringSessionStartOk': ringSessionStartOk,
      'ringSessionPlaythroughAccountingOk': ringSessionPlaythroughAccountingOk,
      'ringSessionChecksumIdentityOk': ringSessionChecksumIdentityOk,
      'ringSessionStopDisposeOk': ringSessionStopDisposeOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    return VGRealtimeAudioPlaybackProductionSmokeReport(
      pass: computedPass,
      status: finalStatus,
      marker: finalMarker,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: failureReason,
      details: details,
      formatProbeOk: formatProbeOk,
      preRollOk: preRollOk,
      startOk: startOk,
      nonZeroGainAudioTrackOk: nonZeroGainAudioTrackOk,
      playthroughAccountingOk: playthroughAccountingOk,
      checksumIdentityOk: checksumIdentityOk,
      clockAnchoredOk: clockAnchoredOk,
      clockMonotonicOk: clockMonotonicOk,
      clockEpochBalancedOk: clockEpochBalancedOk,
      clockPauseFrozenOk: clockPauseFrozenOk,
      boundedPauseResumeOk: boundedPauseResumeOk,
      stopDisposeOk: stopDisposeOk,
      decoderCancelledOnStopOk: decoderCancelledOnStopOk,
      transportDisposedOk: transportDisposedOk,
      audioTrackReleasedOnceOk: audioTrackReleasedOnceOk,
      threadOwnershipOk: threadOwnershipOk,
      noFeedbackOk: noFeedbackOk,
      proofBoundaryOk: proofBoundaryOk,
      syntheticDeadObjectRecoveryOk: syntheticDeadObjectRecoveryOk,
      deadObjectClockEpochRebaseOk: deadObjectClockEpochRebaseOk,
      deadObjectRemainderAccountingOk: deadObjectRemainderAccountingOk,
      seekQuiesceAccountingOk: seekQuiesceAccountingOk,
      seekCommandOk: seekCommandOk,
      sinkFlushAtSeekOk: sinkFlushAtSeekOk,
      decoderSeekReanchorOk: decoderSeekReanchorOk,
      staleGenerationRejectedOk: staleGenerationRejectedOk,
      seekClockEpochOk: seekClockEpochOk,
      postSeekDrainOk: postSeekDrainOk,
      repeatedSeekCommandOk: repeatedSeekCommandOk,
      repeatedSeekCumulativeAccountingOk: repeatedSeekCumulativeAccountingOk,
      repeatedSeekThirdRejectOk: repeatedSeekThirdRejectOk,
      backwardSeekAdmissionOk: backwardSeekAdmissionOk,
      backwardSeekQuiesceAccountingOk: backwardSeekQuiesceAccountingOk,
      backwardSinkFlushAtSeekOk: backwardSinkFlushAtSeekOk,
      backwardSeekCommandOk: backwardSeekCommandOk,
      backwardDecoderReanchorOk: backwardDecoderReanchorOk,
      backwardStaleGenerationRejectedOk: backwardStaleGenerationRejectedOk,
      backwardSeekClockEpochRebaseOk: backwardSeekClockEpochRebaseOk,
      backwardPositionQueryRebaseOk: backwardPositionQueryRebaseOk,
      backwardDriftSampleBoundedOk: backwardDriftSampleBoundedOk,
      backwardClockCorrelationOk: backwardClockCorrelationOk,
      backwardPostSeekFrameAccountingOk: backwardPostSeekFrameAccountingOk,
      backwardSeekRepeatedRejectOk: backwardSeekRepeatedRejectOk,
      backwardNoFeedbackOk: backwardNoFeedbackOk,
      focusSetupOk: focusSetupOk,
      focusDuckRestoreOk: focusDuckRestoreOk,
      focusTransientPauseResumeOk: focusTransientPauseResumeOk,
      focusNoisyTerminalPauseOk: focusNoisyTerminalPauseOk,
      focusPermanentLossPauseOk: focusPermanentLossPauseOk,
      focusMonitorTeardownOk: focusMonitorTeardownOk,
      routingSetupOk: routingSetupOk,
      routeChangeObservationOk: routeChangeObservationOk,
      routeDisconnectTerminalPauseOk: routeDisconnectTerminalPauseOk,
      routeDisconnectResumeBlockedOk: routeDisconnectResumeBlockedOk,
      routingMonitorTeardownOk: routingMonitorTeardownOk,
      currentPositionQuerySurfaceOk: currentPositionQuerySurfaceOk,
      currentPositionPollerMonotonicOk: currentPositionPollerMonotonicOk,
      currentPositionReadCounterIsolationOk:
          currentPositionReadCounterIsolationOk,
      presentationLagTelemetryOk: presentationLagTelemetryOk,
      presentationLagBoundedOk: presentationLagBoundedOk,
      positionAtEosNoRunawayOk: positionAtEosNoRunawayOk,
      positionQueryPauseHoldFrozenOk: positionQueryPauseHoldFrozenOk,
      positionQueryDeadObjectRebaseOk: positionQueryDeadObjectRebaseOk,
      positionQuerySeekBaseAdvanceOk: positionQuerySeekBaseAdvanceOk,
      positionQueryRepeatedSeekBaseAdvanceOk:
          positionQueryRepeatedSeekBaseAdvanceOk,
      positionQueryPostTeardownLatchedOk: positionQueryPostTeardownLatchedOk,
      nativeAudioClockSnapshotPublishedOk: nativeAudioClockSnapshotPublishedOk,
      clockCorrelationTelemetryOk: clockCorrelationTelemetryOk,
      clockObservationNoFeedbackOk: clockObservationNoFeedbackOk,
      driftSampleWorkerOwnedOk: driftSampleWorkerOwnedOk,
      driftSampleGenerationPinnedOk: driftSampleGenerationPinnedOk,
      driftSampleNoFeedbackOk: driftSampleNoFeedbackOk,
      clockAuthorityUnchangedOk: clockAuthorityUnchangedOk,
      ringFrameSourceOk: ringFrameSourceOk,
      realDecoderRingFrameSourceOk: realDecoderRingFrameSourceOk,
      realRingPauseAckOk: realRingPauseAckOk,
      realRingPauseHoldFrozenOk: realRingPauseHoldFrozenOk,
      realRingResumeAckOk: realRingResumeAckOk,
      realRingPostResumeChecksumOk: realRingPostResumeChecksumOk,
      realRingSeekQuiesceAckOk: realRingSeekQuiesceAckOk,
      realRingSeekReanchorOk: realRingSeekReanchorOk,
      realRingSeekPostSeekDrainOk: realRingSeekPostSeekDrainOk,
      realRingSeekChecksumIdentityOk: realRingSeekChecksumIdentityOk,
      ringSessionStartOk: ringSessionStartOk,
      ringSessionPlaythroughAccountingOk: ringSessionPlaythroughAccountingOk,
      ringSessionChecksumIdentityOk: ringSessionChecksumIdentityOk,
      ringSessionStopDisposeOk: ringSessionStopDisposeOk,
      canonical: canonical,
      lanes: Map<String, Object?>.unmodifiable(finalLanes),
      metrics: Map<String, Object?>.unmodifiable(parsedMetrics),
      lastError: finalLastError,
      raw: rawString,
    );
  }

  /// Serializes the report back to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'status': status,
      'marker': marker,
      'proofBoundary': proofBoundary,
      'nativeProofBoundary': nativeProofBoundary,
      'failureReason': failureReason,
      'details': details,
      'lanes': Map<String, Object?>.from(lanes),
      'metrics': Map<String, Object?>.from(metrics),
      'lastError': lastError,
      'raw': raw,
    };
  }

  Map<String, Object?> toJson() => toMap();

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static VGRealtimeAudioPlaybackProductionSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{for (final k in requiredLanes) k: false};
    final metrics = <String, Object?>{
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGRealtimeAudioPlaybackProductionSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      nativeProofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      preRollOk: false,
      startOk: false,
      nonZeroGainAudioTrackOk: false,
      playthroughAccountingOk: false,
      checksumIdentityOk: false,
      clockAnchoredOk: false,
      clockMonotonicOk: false,
      clockEpochBalancedOk: false,
      clockPauseFrozenOk: false,
      boundedPauseResumeOk: false,
      stopDisposeOk: false,
      decoderCancelledOnStopOk: false,
      transportDisposedOk: false,
      audioTrackReleasedOnceOk: false,
      threadOwnershipOk: false,
      noFeedbackOk: false,
      proofBoundaryOk: false,
      syntheticDeadObjectRecoveryOk: false,
      deadObjectClockEpochRebaseOk: false,
      deadObjectRemainderAccountingOk: false,
      seekQuiesceAccountingOk: false,
      seekCommandOk: false,
      sinkFlushAtSeekOk: false,
      decoderSeekReanchorOk: false,
      staleGenerationRejectedOk: false,
      seekClockEpochOk: false,
      postSeekDrainOk: false,
      repeatedSeekCommandOk: false,
      repeatedSeekCumulativeAccountingOk: false,
      repeatedSeekThirdRejectOk: false,
      backwardSeekAdmissionOk: false,
      backwardSeekQuiesceAccountingOk: false,
      backwardSinkFlushAtSeekOk: false,
      backwardSeekCommandOk: false,
      backwardDecoderReanchorOk: false,
      backwardStaleGenerationRejectedOk: false,
      backwardSeekClockEpochRebaseOk: false,
      backwardPositionQueryRebaseOk: false,
      backwardDriftSampleBoundedOk: false,
      backwardClockCorrelationOk: false,
      backwardPostSeekFrameAccountingOk: false,
      backwardSeekRepeatedRejectOk: false,
      backwardNoFeedbackOk: false,
      focusSetupOk: false,
      focusDuckRestoreOk: false,
      focusTransientPauseResumeOk: false,
      focusNoisyTerminalPauseOk: false,
      focusPermanentLossPauseOk: false,
      focusMonitorTeardownOk: false,
      routingSetupOk: false,
      routeChangeObservationOk: false,
      routeDisconnectTerminalPauseOk: false,
      routeDisconnectResumeBlockedOk: false,
      routingMonitorTeardownOk: false,
      currentPositionQuerySurfaceOk: false,
      currentPositionPollerMonotonicOk: false,
      currentPositionReadCounterIsolationOk: false,
      presentationLagTelemetryOk: false,
      presentationLagBoundedOk: false,
      positionAtEosNoRunawayOk: false,
      positionQueryPauseHoldFrozenOk: false,
      positionQueryDeadObjectRebaseOk: false,
      positionQuerySeekBaseAdvanceOk: false,
      positionQueryRepeatedSeekBaseAdvanceOk: false,
      positionQueryPostTeardownLatchedOk: false,
      nativeAudioClockSnapshotPublishedOk: false,
      clockCorrelationTelemetryOk: false,
      clockObservationNoFeedbackOk: false,
      driftSampleWorkerOwnedOk: false,
      driftSampleGenerationPinnedOk: false,
      driftSampleNoFeedbackOk: false,
      clockAuthorityUnchangedOk: false,
      ringFrameSourceOk: false,
      realDecoderRingFrameSourceOk: false,
      realRingPauseAckOk: false,
      realRingPauseHoldFrozenOk: false,
      realRingResumeAckOk: false,
      realRingPostResumeChecksumOk: false,
      realRingSeekQuiesceAckOk: false,
      realRingSeekReanchorOk: false,
      realRingSeekPostSeekDrainOk: false,
      realRingSeekChecksumIdentityOk: false,
      ringSessionStartOk: false,
      ringSessionPlaythroughAccountingOk: false,
      ringSessionChecksumIdentityOk: false,
      ringSessionStopDisposeOk: false,
      canonical: false,
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
      raw: 'pass=false;status=fail;marker=$failMarkerConstant;reason=$reason',
    );
  }

  /// Invokes the Android True-DAG Phase 4 Realtime Audio Playback Production Sink, Clock,
  /// Dead-Object, Forward-Seek, Repeated-Seek, and Focus-Response diagnostic smoke harness.
  ///
  /// [sourcePath] path to a media file with an audio track.
  /// [maxDurationSec] window duration in seconds (default 3.0).
  /// [maxFramesPerMix] quantum mix size in frames (default 256).
  /// [gain] AudioTrack volume gain (default 0.5).
  /// [deadlineMs] total deadline in milliseconds (default 30000).
  /// [pauseHoldMs] duration of pause hold in milliseconds (default 400).
  /// [maxPauseHoldMs] maximum allowed pause hold in milliseconds.
  /// [stopAfterMs] duration to play before mid-playback stop in milliseconds (default 300).
  /// [deadObjectInjectAfterFrames] frames written before synthetic dead object is armed (default 8192).
  /// [seekTargetSec] forward seek target in seconds (default 1.0).
  /// [secondSeekTargetSec] second forward seek target in seconds (default 2.0).
  /// [preSeekHoldWindows] mix windows to hold feed past pre-roll before seek (default 64).
  /// [maxSeekHoldMs] maximum allowed seek hold in milliseconds (default 15000).
  /// [duckGain] target duck gain during transient ducking (default 0.1).
  /// [timeout] optionally bounds the invocation (defaults to 40 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGRealtimeAudioPlaybackProductionSmokeReport>
  runRealtimeAudioPlaybackProductionSmoke({
    required String sourcePath,
    double maxDurationSec = 3.0,
    int maxFramesPerMix = 256,
    double gain = 0.5,
    int deadlineMs = 30000,
    int pauseHoldMs = 400,
    int? maxPauseHoldMs,
    int stopAfterMs = 300,
    int deadObjectInjectAfterFrames = 8192,
    double seekTargetSec = 1.0,
    double secondSeekTargetSec = 2.0,
    int preSeekHoldWindows = 64,
    int? maxSeekHoldMs,
    double duckGain = 0.1,
    Duration timeout = const Duration(seconds: 40),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName, <String, dynamic>{
        'sourcePath': sourcePath,
        'maxDurationSec': maxDurationSec,
        'maxFramesPerMix': maxFramesPerMix,
        'gain': gain,
        'deadlineMs': deadlineMs,
        'pauseHoldMs': pauseHoldMs,
        'maxPauseHoldMs': ?maxPauseHoldMs,
        'stopAfterMs': stopAfterMs,
        'deadObjectInjectAfterFrames': deadObjectInjectAfterFrames,
        'seekTargetSec': seekTargetSec,
        'secondSeekTargetSec': secondSeekTargetSec,
        'preSeekHoldWindows': preSeekHoldWindows,
        'maxSeekHoldMs': ?maxSeekHoldMs,
        'duckGain': duckGain,
      });
      final raw = await future.timeout(timeout);
      return VGRealtimeAudioPlaybackProductionSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return _makeErrorFallbackReport(
        reason: 'timeout',
        details: te.toString(),
        lastError: 'timeout: $te',
      );
    } on PlatformException catch (pe) {
      return _makeErrorFallbackReport(
        reason: 'platform_exception:${pe.code}',
        details: pe.message ?? '',
        lastError: 'platform_exception:${pe.code}:${pe.message}',
      );
    } catch (e) {
      return _makeErrorFallbackReport(
        reason: 'exception:$e',
        details: e.toString(),
        lastError: 'exception:$e',
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGRealtimeAudioPlaybackProductionSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.nativeProofBoundary == nativeProofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.formatProbeOk == formatProbeOk &&
        other.preRollOk == preRollOk &&
        other.startOk == startOk &&
        other.nonZeroGainAudioTrackOk == nonZeroGainAudioTrackOk &&
        other.playthroughAccountingOk == playthroughAccountingOk &&
        other.checksumIdentityOk == checksumIdentityOk &&
        other.clockAnchoredOk == clockAnchoredOk &&
        other.clockMonotonicOk == clockMonotonicOk &&
        other.clockEpochBalancedOk == clockEpochBalancedOk &&
        other.clockPauseFrozenOk == clockPauseFrozenOk &&
        other.boundedPauseResumeOk == boundedPauseResumeOk &&
        other.stopDisposeOk == stopDisposeOk &&
        other.decoderCancelledOnStopOk == decoderCancelledOnStopOk &&
        other.transportDisposedOk == transportDisposedOk &&
        other.audioTrackReleasedOnceOk == audioTrackReleasedOnceOk &&
        other.threadOwnershipOk == threadOwnershipOk &&
        other.noFeedbackOk == noFeedbackOk &&
        other.proofBoundaryOk == proofBoundaryOk &&
        other.syntheticDeadObjectRecoveryOk == syntheticDeadObjectRecoveryOk &&
        other.deadObjectClockEpochRebaseOk == deadObjectClockEpochRebaseOk &&
        other.deadObjectRemainderAccountingOk ==
            deadObjectRemainderAccountingOk &&
        other.seekQuiesceAccountingOk == seekQuiesceAccountingOk &&
        other.seekCommandOk == seekCommandOk &&
        other.sinkFlushAtSeekOk == sinkFlushAtSeekOk &&
        other.decoderSeekReanchorOk == decoderSeekReanchorOk &&
        other.staleGenerationRejectedOk == staleGenerationRejectedOk &&
        other.seekClockEpochOk == seekClockEpochOk &&
        other.postSeekDrainOk == postSeekDrainOk &&
        other.repeatedSeekCommandOk == repeatedSeekCommandOk &&
        other.repeatedSeekCumulativeAccountingOk ==
            repeatedSeekCumulativeAccountingOk &&
        other.repeatedSeekThirdRejectOk == repeatedSeekThirdRejectOk &&
        other.backwardSeekAdmissionOk == backwardSeekAdmissionOk &&
        other.backwardSeekQuiesceAccountingOk ==
            backwardSeekQuiesceAccountingOk &&
        other.backwardSinkFlushAtSeekOk == backwardSinkFlushAtSeekOk &&
        other.backwardSeekCommandOk == backwardSeekCommandOk &&
        other.backwardDecoderReanchorOk == backwardDecoderReanchorOk &&
        other.backwardStaleGenerationRejectedOk ==
            backwardStaleGenerationRejectedOk &&
        other.backwardSeekClockEpochRebaseOk ==
            backwardSeekClockEpochRebaseOk &&
        other.backwardPositionQueryRebaseOk == backwardPositionQueryRebaseOk &&
        other.backwardDriftSampleBoundedOk == backwardDriftSampleBoundedOk &&
        other.backwardClockCorrelationOk == backwardClockCorrelationOk &&
        other.backwardPostSeekFrameAccountingOk ==
            backwardPostSeekFrameAccountingOk &&
        other.backwardSeekRepeatedRejectOk == backwardSeekRepeatedRejectOk &&
        other.backwardNoFeedbackOk == backwardNoFeedbackOk &&
        other.focusSetupOk == focusSetupOk &&
        other.focusDuckRestoreOk == focusDuckRestoreOk &&
        other.focusTransientPauseResumeOk == focusTransientPauseResumeOk &&
        other.focusNoisyTerminalPauseOk == focusNoisyTerminalPauseOk &&
        other.focusPermanentLossPauseOk == focusPermanentLossPauseOk &&
        other.focusMonitorTeardownOk == focusMonitorTeardownOk &&
        other.routingSetupOk == routingSetupOk &&
        other.routeChangeObservationOk == routeChangeObservationOk &&
        other.routeDisconnectTerminalPauseOk ==
            routeDisconnectTerminalPauseOk &&
        other.routeDisconnectResumeBlockedOk ==
            routeDisconnectResumeBlockedOk &&
        other.routingMonitorTeardownOk == routingMonitorTeardownOk &&
        other.currentPositionQuerySurfaceOk == currentPositionQuerySurfaceOk &&
        other.currentPositionPollerMonotonicOk ==
            currentPositionPollerMonotonicOk &&
        other.currentPositionReadCounterIsolationOk ==
            currentPositionReadCounterIsolationOk &&
        other.presentationLagTelemetryOk == presentationLagTelemetryOk &&
        other.presentationLagBoundedOk == presentationLagBoundedOk &&
        other.positionAtEosNoRunawayOk == positionAtEosNoRunawayOk &&
        other.positionQueryPauseHoldFrozenOk ==
            positionQueryPauseHoldFrozenOk &&
        other.positionQueryDeadObjectRebaseOk ==
            positionQueryDeadObjectRebaseOk &&
        other.positionQuerySeekBaseAdvanceOk ==
            positionQuerySeekBaseAdvanceOk &&
        other.positionQueryRepeatedSeekBaseAdvanceOk ==
            positionQueryRepeatedSeekBaseAdvanceOk &&
        other.positionQueryPostTeardownLatchedOk ==
            positionQueryPostTeardownLatchedOk &&
        other.nativeAudioClockSnapshotPublishedOk ==
            nativeAudioClockSnapshotPublishedOk &&
        other.clockCorrelationTelemetryOk == clockCorrelationTelemetryOk &&
        other.clockObservationNoFeedbackOk == clockObservationNoFeedbackOk &&
        other.driftSampleWorkerOwnedOk == driftSampleWorkerOwnedOk &&
        other.driftSampleGenerationPinnedOk == driftSampleGenerationPinnedOk &&
        other.driftSampleNoFeedbackOk == driftSampleNoFeedbackOk &&
        other.clockAuthorityUnchangedOk == clockAuthorityUnchangedOk &&
        other.ringFrameSourceOk == ringFrameSourceOk &&
        other.realDecoderRingFrameSourceOk == realDecoderRingFrameSourceOk &&
        other.realRingPauseAckOk == realRingPauseAckOk &&
        other.realRingPauseHoldFrozenOk == realRingPauseHoldFrozenOk &&
        other.realRingResumeAckOk == realRingResumeAckOk &&
        other.realRingPostResumeChecksumOk == realRingPostResumeChecksumOk &&
        other.realRingSeekQuiesceAckOk == realRingSeekQuiesceAckOk &&
        other.realRingSeekReanchorOk == realRingSeekReanchorOk &&
        other.realRingSeekPostSeekDrainOk == realRingSeekPostSeekDrainOk &&
        other.realRingSeekChecksumIdentityOk ==
            realRingSeekChecksumIdentityOk &&
        other.ringSessionStartOk == ringSessionStartOk &&
        other.ringSessionPlaythroughAccountingOk ==
            ringSessionPlaythroughAccountingOk &&
        other.ringSessionChecksumIdentityOk == ringSessionChecksumIdentityOk &&
        other.ringSessionStopDisposeOk == ringSessionStopDisposeOk &&
        other.canonical == canonical &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    pass,
    status,
    marker,
    proofBoundary,
    nativeProofBoundary,
    failureReason,
    details,
    formatProbeOk,
    preRollOk,
    startOk,
    nonZeroGainAudioTrackOk,
    playthroughAccountingOk,
    checksumIdentityOk,
    clockAnchoredOk,
    clockMonotonicOk,
    clockEpochBalancedOk,
    clockPauseFrozenOk,
    boundedPauseResumeOk,
    stopDisposeOk,
    decoderCancelledOnStopOk,
    transportDisposedOk,
    audioTrackReleasedOnceOk,
    threadOwnershipOk,
    noFeedbackOk,
    proofBoundaryOk,
    syntheticDeadObjectRecoveryOk,
    deadObjectClockEpochRebaseOk,
    deadObjectRemainderAccountingOk,
    seekQuiesceAccountingOk,
    seekCommandOk,
    sinkFlushAtSeekOk,
    decoderSeekReanchorOk,
    staleGenerationRejectedOk,
    seekClockEpochOk,
    postSeekDrainOk,
    repeatedSeekCommandOk,
    repeatedSeekCumulativeAccountingOk,
    repeatedSeekThirdRejectOk,
    backwardSeekAdmissionOk,
    backwardSeekQuiesceAccountingOk,
    backwardSinkFlushAtSeekOk,
    backwardSeekCommandOk,
    backwardDecoderReanchorOk,
    backwardStaleGenerationRejectedOk,
    backwardSeekClockEpochRebaseOk,
    backwardPositionQueryRebaseOk,
    backwardDriftSampleBoundedOk,
    backwardClockCorrelationOk,
    backwardPostSeekFrameAccountingOk,
    backwardSeekRepeatedRejectOk,
    backwardNoFeedbackOk,
    focusSetupOk,
    focusDuckRestoreOk,
    focusTransientPauseResumeOk,
    focusNoisyTerminalPauseOk,
    focusPermanentLossPauseOk,
    focusMonitorTeardownOk,
    routingSetupOk,
    routeChangeObservationOk,
    routeDisconnectTerminalPauseOk,
    routeDisconnectResumeBlockedOk,
    routingMonitorTeardownOk,
    currentPositionQuerySurfaceOk,
    currentPositionPollerMonotonicOk,
    currentPositionReadCounterIsolationOk,
    presentationLagTelemetryOk,
    presentationLagBoundedOk,
    positionAtEosNoRunawayOk,
    positionQueryPauseHoldFrozenOk,
    positionQueryDeadObjectRebaseOk,
    positionQuerySeekBaseAdvanceOk,
    positionQueryRepeatedSeekBaseAdvanceOk,
    positionQueryPostTeardownLatchedOk,
    nativeAudioClockSnapshotPublishedOk,
    clockCorrelationTelemetryOk,
    clockObservationNoFeedbackOk,
    driftSampleWorkerOwnedOk,
    driftSampleGenerationPinnedOk,
    driftSampleNoFeedbackOk,
    clockAuthorityUnchangedOk,
    ringFrameSourceOk,
    realDecoderRingFrameSourceOk,
    realRingPauseAckOk,
    realRingPauseHoldFrozenOk,
    realRingResumeAckOk,
    realRingPostResumeChecksumOk,
    realRingSeekQuiesceAckOk,
    realRingSeekReanchorOk,
    realRingSeekPostSeekDrainOk,
    realRingSeekChecksumIdentityOk,
    ringSessionStartOk,
    ringSessionPlaythroughAccountingOk,
    ringSessionChecksumIdentityOk,
    ringSessionStopDisposeOk,
    canonical,
  ]);

  @override
  String toString() =>
      'VGRealtimeAudioPlaybackProductionSmokeReport(pass: $pass, status: $status, '
      'marker: $marker, isVerifiedPass: $isVerifiedPass, '
      'formatProbeOk: $formatProbeOk, preRollOk: $preRollOk, startOk: $startOk, '
      'nonZeroGainAudioTrackOk: $nonZeroGainAudioTrackOk, '
      'playthroughAccountingOk: $playthroughAccountingOk, checksumIdentityOk: $checksumIdentityOk, '
      'clockAnchoredOk: $clockAnchoredOk, clockMonotonicOk: $clockMonotonicOk, '
      'clockEpochBalancedOk: $clockEpochBalancedOk, clockPauseFrozenOk: $clockPauseFrozenOk, '
      'boundedPauseResumeOk: $boundedPauseResumeOk, stopDisposeOk: $stopDisposeOk, '
      'decoderCancelledOnStopOk: $decoderCancelledOnStopOk, transportDisposedOk: $transportDisposedOk, '
      'audioTrackReleasedOnceOk: $audioTrackReleasedOnceOk, threadOwnershipOk: $threadOwnershipOk, '
      'noFeedbackOk: $noFeedbackOk, proofBoundaryOk: $proofBoundaryOk, '
      'syntheticDeadObjectRecoveryOk: $syntheticDeadObjectRecoveryOk, '
      'deadObjectClockEpochRebaseOk: $deadObjectClockEpochRebaseOk, '
      'deadObjectRemainderAccountingOk: $deadObjectRemainderAccountingOk, '
      'seekQuiesceAccountingOk: $seekQuiesceAccountingOk, seekCommandOk: $seekCommandOk, '
      'sinkFlushAtSeekOk: $sinkFlushAtSeekOk, decoderSeekReanchorOk: $decoderSeekReanchorOk, '
      'staleGenerationRejectedOk: $staleGenerationRejectedOk, seekClockEpochOk: $seekClockEpochOk, '
      'postSeekDrainOk: $postSeekDrainOk, '
      'repeatedSeekCommandOk: $repeatedSeekCommandOk, '
      'repeatedSeekCumulativeAccountingOk: $repeatedSeekCumulativeAccountingOk, '
      'repeatedSeekThirdRejectOk: $repeatedSeekThirdRejectOk, '
      'backwardSeekAdmissionOk: $backwardSeekAdmissionOk, '
      'backwardSeekQuiesceAccountingOk: $backwardSeekQuiesceAccountingOk, '
      'backwardSinkFlushAtSeekOk: $backwardSinkFlushAtSeekOk, '
      'backwardSeekCommandOk: $backwardSeekCommandOk, '
      'backwardDecoderReanchorOk: $backwardDecoderReanchorOk, '
      'backwardStaleGenerationRejectedOk: $backwardStaleGenerationRejectedOk, '
      'backwardSeekClockEpochRebaseOk: $backwardSeekClockEpochRebaseOk, '
      'backwardPositionQueryRebaseOk: $backwardPositionQueryRebaseOk, '
      'backwardDriftSampleBoundedOk: $backwardDriftSampleBoundedOk, '
      'backwardClockCorrelationOk: $backwardClockCorrelationOk, '
      'backwardPostSeekFrameAccountingOk: $backwardPostSeekFrameAccountingOk, '
      'backwardSeekRepeatedRejectOk: $backwardSeekRepeatedRejectOk, '
      'backwardNoFeedbackOk: $backwardNoFeedbackOk, '
      'focusSetupOk: $focusSetupOk, focusDuckRestoreOk: $focusDuckRestoreOk, '
      'focusTransientPauseResumeOk: $focusTransientPauseResumeOk, '
      'focusNoisyTerminalPauseOk: $focusNoisyTerminalPauseOk, '
      'focusPermanentLossPauseOk: $focusPermanentLossPauseOk, '
      'focusMonitorTeardownOk: $focusMonitorTeardownOk, '
      'routingSetupOk: $routingSetupOk, '
      'routeChangeObservationOk: $routeChangeObservationOk, '
      'routeDisconnectTerminalPauseOk: $routeDisconnectTerminalPauseOk, '
      'routeDisconnectResumeBlockedOk: $routeDisconnectResumeBlockedOk, '
      'routingMonitorTeardownOk: $routingMonitorTeardownOk, '
      'currentPositionQuerySurfaceOk: $currentPositionQuerySurfaceOk, '
      'currentPositionPollerMonotonicOk: $currentPositionPollerMonotonicOk, '
      'currentPositionReadCounterIsolationOk: $currentPositionReadCounterIsolationOk, '
      'presentationLagTelemetryOk: $presentationLagTelemetryOk, '
      'presentationLagBoundedOk: $presentationLagBoundedOk, '
      'positionAtEosNoRunawayOk: $positionAtEosNoRunawayOk, '
      'positionQueryPauseHoldFrozenOk: $positionQueryPauseHoldFrozenOk, '
      'positionQueryDeadObjectRebaseOk: $positionQueryDeadObjectRebaseOk, '
      'positionQuerySeekBaseAdvanceOk: $positionQuerySeekBaseAdvanceOk, '
      'positionQueryRepeatedSeekBaseAdvanceOk: $positionQueryRepeatedSeekBaseAdvanceOk, '
      'positionQueryPostTeardownLatchedOk: $positionQueryPostTeardownLatchedOk, '
      'nativeAudioClockSnapshotPublishedOk: $nativeAudioClockSnapshotPublishedOk, '
      'clockCorrelationTelemetryOk: $clockCorrelationTelemetryOk, '
      'clockObservationNoFeedbackOk: $clockObservationNoFeedbackOk, '
      'driftSampleWorkerOwnedOk: $driftSampleWorkerOwnedOk, '
      'driftSampleGenerationPinnedOk: $driftSampleGenerationPinnedOk, '
      'driftSampleNoFeedbackOk: $driftSampleNoFeedbackOk, '
      'clockAuthorityUnchangedOk: $clockAuthorityUnchangedOk, '
      'ringFrameSourceOk: $ringFrameSourceOk, '
      'realDecoderRingFrameSourceOk: $realDecoderRingFrameSourceOk, '
      'realRingPauseAckOk: $realRingPauseAckOk, '
      'realRingPauseHoldFrozenOk: $realRingPauseHoldFrozenOk, '
      'realRingResumeAckOk: $realRingResumeAckOk, '
      'realRingPostResumeChecksumOk: $realRingPostResumeChecksumOk, '
      'realRingSeekQuiesceAckOk: $realRingSeekQuiesceAckOk, '
      'realRingSeekReanchorOk: $realRingSeekReanchorOk, '
      'realRingSeekPostSeekDrainOk: $realRingSeekPostSeekDrainOk, '
      'realRingSeekChecksumIdentityOk: $realRingSeekChecksumIdentityOk, '
      'ringSessionStartOk: $ringSessionStartOk, '
      'ringSessionPlaythroughAccountingOk: $ringSessionPlaythroughAccountingOk, '
      'ringSessionChecksumIdentityOk: $ringSessionChecksumIdentityOk, '
      'ringSessionStopDisposeOk: $ringSessionStopDisposeOk, '
      'canonical: $canonical, '
      'failureReason: $failureReason, lastError: $lastError)';

  // ---- Focus and Sink Telemetry Getters ----------------------------------

  /// Whether audio focus response was enabled.
  bool get focusEnabled => metrics['focusEnabled'] == true;

  /// Number of focus duck transitions applied.
  int get focusDuckAppliedCount =>
      (metrics['focusDuckAppliedCount'] as num?)?.toInt() ?? 0;

  /// Number of focus gain restore transitions applied.
  int get focusGainRestoreAppliedCount =>
      (metrics['focusGainRestoreAppliedCount'] as num?)?.toInt() ?? 0;

  /// Number of transient pause transitions applied by policy.
  int get focusPauseTransientAppliedCount =>
      (metrics['focusPauseTransientAppliedCount'] as num?)?.toInt() ?? 0;

  /// Number of noisy pause transitions applied.
  int get focusPauseNoisyAppliedCount =>
      (metrics['focusPauseNoisyAppliedCount'] as num?)?.toInt() ?? 0;

  /// Number of permanent loss pause transitions applied.
  int get focusPausePermanentAppliedCount =>
      (metrics['focusPausePermanentAppliedCount'] as num?)?.toInt() ?? 0;

  /// Number of auto-resume transitions applied by policy.
  int get focusAutoResumeAppliedCount =>
      (metrics['focusAutoResumeAppliedCount'] as num?)?.toInt() ?? 0;

  /// Focus state string if available (e.g. "held", "ducked", "lost_transient", "noisy", "lost_permanent").
  String get focusState => metrics['focusState']?.toString() ?? '';

  /// Sink effective linear gain if available.
  double get sinkEffectiveGain =>
      (metrics['sinkEffectiveGain'] as num?)?.toDouble() ?? 0.0;

  /// Number of focus events drained after ignored gain event.
  int get ignoredGainEventsDrained =>
      (metrics['ignoredGainEventsDrained'] as num?)?.toInt() ?? 0;

  /// Number of focus gain restore transitions applied after ignored gain event.
  int get ignoredGainRestoreAppliedCount =>
      (metrics['ignoredGainRestoreAppliedCount'] as num?)?.toInt() ?? 0;

  /// Number of auto-resume transitions applied after ignored gain event.
  int get ignoredGainAutoResumeCount =>
      (metrics['ignoredGainAutoResumeCount'] as num?)?.toInt() ?? 0;

  // ---- Routing Telemetry Getters ----------------------------------------

  /// Whether audio routing response was enabled.
  bool get routingEnabled => metrics['routingEnabled'] == true;

  /// Whether routing controller is attached.
  bool get routingControllerAttached =>
      metrics['routingControllerAttached'] == true;

  /// Whether routing controller is released.
  bool get routingControllerReleased =>
      metrics['routingControllerReleased'] == true;

  /// Number of routing attach attempts.
  int get routingAttachCount =>
      (metrics['routingAttachCount'] as num?)?.toInt() ?? 0;

  /// Number of routing detach attempts.
  int get routingDetachCount =>
      (metrics['routingDetachCount'] as num?)?.toInt() ?? 0;

  /// Number of route change transitions applied.
  int get routeChangedAppliedCount =>
      (metrics['routeChangedAppliedCount'] as num?)?.toInt() ?? 0;

  /// Number of route disconnect transitions applied.
  int get routeDisconnectAppliedCount =>
      (metrics['routeDisconnectAppliedCount'] as num?)?.toInt() ?? 0;

  /// Whether terminal route disconnect was triggered.
  bool get routingTerminalDisconnect =>
      metrics['routingTerminalDisconnect'] == true;

  /// Whether playback was paused by routing policy.
  bool get routingPausedByPolicy => metrics['routingPausedByPolicy'] == true;

  /// Last observed routing action string.
  String get routingLastAction =>
      metrics['routingLastAction']?.toString() ?? '';

  /// Last observed routing reason string.
  String get routingLastReason =>
      metrics['routingLastReason']?.toString() ?? '';

  /// Whether public resume call was accepted during routing disconnect proof.
  bool get publicResumeAccepted => metrics['publicResumeAccepted'] == true;

  /// Public resume rejection reason during routing disconnect proof.
  String get publicResumeReason =>
      metrics['publicResumeReason']?.toString() ?? '';

  // ---- Presentation Clock and Lag Telemetry Getters -----------------------

  /// Epoch base frame at epoch open.
  int get epochBaseFrame => (metrics['epochBaseFrame'] as num?)?.toInt() ?? -1;

  /// Frames written to sink at epoch open.
  int get framesWrittenAtEpochOpen =>
      (metrics['framesWrittenAtEpochOpen'] as num?)?.toInt() ?? -1;

  /// Frames read from transport at epoch open.
  int get framesReadAtEpochOpen =>
      (metrics['framesReadAtEpochOpen'] as num?)?.toInt() ?? -1;

  /// Number of eligible presentation lag samples recorded.
  int get presentationLagSampleCount =>
      (metrics['presentationLagSampleCount'] as num?)?.toInt() ?? 0;

  /// Number of presentation lag samples within analytical bounds.
  int get presentationLagBoundedSampleCount =>
      (metrics['presentationLagBoundedSampleCount'] as num?)?.toInt() ?? 0;

  /// Number of presentation lag samples excluded (e.g. RESET/STALE/no-anchor).
  int get presentationLagExcludedSampleCount =>
      (metrics['presentationLagExcludedSampleCount'] as num?)?.toInt() ?? 0;

  /// Last observed presentation lag in frames.
  int get lastPresentationLagFrames =>
      (metrics['lastPresentationLagFrames'] as num?)?.toInt() ?? 0;

  /// Minimum observed presentation lag in frames.
  int get minPresentationLagFrames =>
      (metrics['minPresentationLagFrames'] as num?)?.toInt() ?? 0;

  /// Maximum observed presentation lag in frames.
  int get maxPresentationLagFrames =>
      (metrics['maxPresentationLagFrames'] as num?)?.toInt() ?? 0;

  /// Presentation lag lower bound in frames.
  int get presentationLagLowerBoundFrames =>
      (metrics['presentationLagLowerBoundFrames'] as num?)?.toInt() ?? 0;

  /// Presentation lag upper bound in frames.
  int get presentationLagUpperBoundFrames =>
      (metrics['presentationLagUpperBoundFrames'] as num?)?.toInt() ?? 0;

  /// Last published presentation clock position in frames at poll time.
  int get lastPositionFramesAtPoll =>
      (metrics['lastPositionFramesAtPoll'] as num?)?.toInt() ?? -1;

  /// Last published presentation clock position in microseconds at poll time.
  int get lastPositionUsAtPoll =>
      (metrics['lastPositionUsAtPoll'] as num?)?.toInt() ?? -1;

  /// Presentation clock position in frames recorded at EOS.
  int get positionAtEosFrames =>
      (metrics['positionAtEosFrames'] as num?)?.toInt() ?? -1;

  /// Presentation clock position in microseconds recorded at EOS.
  int get positionAtEosUs =>
      (metrics['positionAtEosUs'] as num?)?.toInt() ?? -1;

  /// Count of currentPosition reads executed from writer/sink thread.
  int get currentPositionReadsFromWriterThread =>
      (metrics['currentPositionReadsFromWriterThread'] as num?)?.toInt() ?? 0;

  /// Count of currentPosition reads executed from other (non-writer) threads.
  int get currentPositionReadsFromOtherThreads =>
      (metrics['currentPositionReadsFromOtherThreads'] as num?)?.toInt() ?? 0;

  // ---- Presentation Clock Poller Getters ----------------------------------

  /// Total polls executed by the off-thread poller.
  int get pollerPollCount => (metrics['pollerPollCount'] as num?)?.toInt() ?? 0;

  /// Valid non-negative position reads recorded by the off-thread poller.
  int get pollerValidCount =>
      (metrics['pollerValidCount'] as num?)?.toInt() ?? 0;

  /// Regressions observed by the off-thread poller.
  int get pollerRegressionCount =>
      (metrics['pollerRegressionCount'] as num?)?.toInt() ?? 0;

  /// Total frame reads executed by the off-thread poller.
  int get pollerFrameReadCount =>
      (metrics['pollerFrameReadCount'] as num?)?.toInt() ?? 0;

  /// Total microseconds reads executed by the off-thread poller.
  int get pollerUsReadCount =>
      (metrics['pollerUsReadCount'] as num?)?.toInt() ?? 0;

  /// Last frame value read by the off-thread poller.
  int get pollerLastFrame =>
      (metrics['pollerLastFrame'] as num?)?.toInt() ?? -1;

  /// Last microseconds value read by the off-thread poller.
  int get pollerLastUs => (metrics['pollerLastUs'] as num?)?.toInt() ?? -1;

  /// Minimum frame value read by the off-thread poller.
  int get pollerMinFrame => (metrics['pollerMinFrame'] as num?)?.toInt() ?? -1;

  /// Maximum frame value read by the off-thread poller.
  int get pollerMaxFrame => (metrics['pollerMaxFrame'] as num?)?.toInt() ?? -1;

  /// Minimum microseconds value read by the off-thread poller.
  int get pollerMinUs => (metrics['pollerMinUs'] as num?)?.toInt() ?? -1;

  /// Maximum microseconds value read by the off-thread poller.
  int get pollerMaxUs => (metrics['pollerMaxUs'] as num?)?.toInt() ?? -1;

  /// Thread ID of the off-thread poller.
  int get pollerThreadId => (metrics['pollerThreadId'] as num?)?.toInt() ?? 0;

  /// Off-thread poller joined flag.
  bool get pollerJoined => metrics['pollerJoined'] == true;

  /// Error string reported by the off-thread poller, if any.
  String get pollerError => metrics['pollerError']?.toString() ?? '';

  // ---- Position Query Lifecycle Discontinuity Getters (Y14) ----------------

  /// Frame position queried at start of pause hold.
  int get pauseStartQueryFrames =>
      (metrics['pauseStartQueryFrames'] as num?)?.toInt() ?? -1;

  /// Microsecond position queried at start of pause hold.
  int get pauseStartQueryUs =>
      (metrics['pauseStartQueryUs'] as num?)?.toInt() ?? -1;

  /// Frame position queried at end of pause hold.
  int get pauseEndQueryFrames =>
      (metrics['pauseEndQueryFrames'] as num?)?.toInt() ?? -1;

  /// Microsecond position queried at end of pause hold.
  int get pauseEndQueryUs =>
      (metrics['pauseEndQueryUs'] as num?)?.toInt() ?? -1;

  /// Frame position queried after synthetic dead-object recovery.
  int get afterRecoveryQueryFrames =>
      (metrics['afterRecoveryQueryFrames'] as num?)?.toInt() ?? -1;

  /// Microsecond position queried after synthetic dead-object recovery.
  int get afterRecoveryQueryUs =>
      (metrics['afterRecoveryQueryUs'] as num?)?.toInt() ?? -1;

  /// Frame position queried after forward seek.
  int get afterSeekQueryFrames =>
      (metrics['afterSeekQueryFrames'] as num?)?.toInt() ?? -1;

  /// Microsecond position queried after forward seek.
  int get afterSeekQueryUs =>
      (metrics['afterSeekQueryUs'] as num?)?.toInt() ?? -1;

  /// Frame position queried after repeated seek T1.
  int get afterSeek1QueryFrames =>
      (metrics['afterSeek1QueryFrames'] as num?)?.toInt() ?? -1;

  /// Microsecond position queried after repeated seek T1.
  int get afterSeek1QueryUs =>
      (metrics['afterSeek1QueryUs'] as num?)?.toInt() ?? -1;

  /// Frame position queried after repeated seek T2.
  int get afterSeek2QueryFrames =>
      (metrics['afterSeek2QueryFrames'] as num?)?.toInt() ?? -1;

  /// Microsecond position queried after repeated seek T2.
  int get afterSeek2QueryUs =>
      (metrics['afterSeek2QueryUs'] as num?)?.toInt() ?? -1;

  /// Frame position queried after rejected 3rd seek.
  int get afterSeek3QueryFrames =>
      (metrics['afterSeek3QueryFrames'] as num?)?.toInt() ?? -1;

  /// Microsecond position queried after rejected 3rd seek.
  int get afterSeek3QueryUs =>
      (metrics['afterSeek3QueryUs'] as num?)?.toInt() ?? -1;

  /// Post-teardown latched currentPositionFrames read.
  int get postTeardownCurrentPositionFrames =>
      (metrics['postTeardownCurrentPositionFrames'] as num?)?.toInt() ?? -1;

  /// Post-teardown latched currentPositionUs read.
  int get postTeardownCurrentPositionUs =>
      (metrics['postTeardownCurrentPositionUs'] as num?)?.toInt() ?? -1;

  // ---- Native Clock Correlation Observation Getters (Y15) ------------------

  /// Native audio clock state token from correlation observation.
  String get nativeClockState =>
      metrics['nativeClockState']?.toString() ??
      (metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
              as Map?)?['nativeClockState']
          ?.toString() ??
      '';

  /// Native audio clock position in microseconds at correlation observation.
  int get nativeClockPositionUs =>
      (metrics['nativeClockPositionUs'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['nativeClockPositionUs']
              as num?)
          ?.toInt() ??
      -1;

  /// Native audio clock position in frames at correlation observation.
  int get nativeClockPositionFrame =>
      (metrics['nativeClockPositionFrame'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['nativeClockPositionFrame']
              as num?)
          ?.toInt() ??
      -1;

  /// Native clock drift sample count at correlation observation.
  int get nativeClockDriftSampleCount =>
      (metrics['nativeClockDriftSampleCount'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['nativeClockDriftSampleCount']
              as num?)
          ?.toInt() ??
      -1;

  /// Presentation clock position in microseconds at correlation observation.
  int get presentationClockPositionUsAtCorrelation =>
      (metrics['presentationClockPositionUsAtCorrelation'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['presentationClockPositionUsAtCorrelation']
              as num?)
          ?.toInt() ??
      -1;

  /// Presentation clock position in frames at correlation observation.
  int get presentationClockPositionFramesAtCorrelation =>
      (metrics['presentationClockPositionFramesAtCorrelation'] as num?)
          ?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['presentationClockPositionFramesAtCorrelation']
              as num?)
          ?.toInt() ??
      -1;

  /// Clock correlation offset in microseconds (presentationUs - nativeUs).
  int get clockCorrelationOffsetUs =>
      (metrics['clockCorrelationOffsetUs'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['clockCorrelationOffsetUs']
              as num?)
          ?.toInt() ??
      -1;

  /// Clock correlation offset in frames (presentationFrames - nativeFrames).
  int get clockCorrelationOffsetFrames =>
      (metrics['clockCorrelationOffsetFrames'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['clockCorrelationOffsetFrames']
              as num?)
          ?.toInt() ??
      -1;

  /// Session commandsIssued count immediately before observeClockCorrelation.
  int get clockCorrelationCommandsBefore =>
      (metrics['clockCorrelationCommandsBefore'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['clockCorrelationCommandsBefore']
              as num?)
          ?.toInt() ??
      -1;

  /// Session commandsIssued count immediately after observeClockCorrelation.
  int get clockCorrelationCommandsAfter =>
      (metrics['clockCorrelationCommandsAfter'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['clockCorrelationCommandsAfter']
              as num?)
          ?.toInt() ??
      -1;

  // ---- Clock Drift Sample Ownership Getters (Y16) -------------------------

  /// Drift samples posted count.
  int get driftSamplesPosted =>
      (metrics['driftSamplesPosted'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftSamplesPosted']
              as num?)
          ?.toInt() ??
      -1;

  /// Drift samples skipped count.
  int get driftSamplesSkipped =>
      (metrics['driftSamplesSkipped'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftSamplesSkipped']
              as num?)
          ?.toInt() ??
      -1;

  /// Drift samples dropped count.
  int get driftSamplesDropped =>
      (metrics['driftSamplesDropped'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftSamplesDropped']
              as num?)
          ?.toInt() ??
      -1;

  /// Drift callback invocation count.
  int get driftCallbackCount =>
      (metrics['driftCallbackCount'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftCallbackCount']
              as num?)
          ?.toInt() ??
      -1;

  /// Drift samples recorded count.
  int get driftSamplesRecorded =>
      (metrics['driftSamplesRecorded'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftSamplesRecorded']
              as num?)
          ?.toInt() ??
      -1;

  /// Drift samples rejected due to stale generation count.
  int get driftSamplesStaleRejected =>
      (metrics['driftSamplesStaleRejected'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftSamplesStaleRejected']
              as num?)
          ?.toInt() ??
      -1;

  /// Drift samples rejected due to other reasons count.
  int get driftSamplesOtherRejected =>
      (metrics['driftSamplesOtherRejected'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftSamplesOtherRejected']
              as num?)
          ?.toInt() ??
      -1;

  /// Last reject reason token for drift samples.
  String get driftLastRejectReason =>
      metrics['driftLastRejectReason']?.toString() ??
      (metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
              as Map?)?['driftLastRejectReason']
          ?.toString() ??
      '';

  /// Maximum queue latency in nanoseconds for drift samples.
  int get driftMaxQueueLatencyNs =>
      (metrics['driftMaxQueueLatencyNs'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftMaxQueueLatencyNs']
              as num?)
          ?.toInt() ??
      -1;

  /// Last posted generation for drift samples.
  int get driftLastPostedGeneration =>
      (metrics['driftLastPostedGeneration'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftLastPostedGeneration']
              as num?)
          ?.toInt() ??
      -1;

  /// Last expected PTS in microseconds for drift samples.
  int get driftLastExpectedPtsUs =>
      (metrics['driftLastExpectedPtsUs'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftLastExpectedPtsUs']
              as num?)
          ?.toInt() ??
      -1;

  /// Last reported PTS in microseconds for drift samples.
  int get driftLastReportedPtsUs =>
      (metrics['driftLastReportedPtsUs'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftLastReportedPtsUs']
              as num?)
          ?.toInt() ??
      -1;

  /// Last drift delta in microseconds.
  int get driftLastDeltaUs =>
      (metrics['driftLastDeltaUs'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftLastDeltaUs']
              as num?)
          ?.toInt() ??
      -1;

  /// Last reported frame for drift samples.
  int get driftLastReportedFrame =>
      (metrics['driftLastReportedFrame'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftLastReportedFrame']
              as num?)
          ?.toInt() ??
      -1;

  /// Native clock drift sample count.
  int get driftNativeSampleCount =>
      (metrics['driftNativeSampleCount'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftNativeSampleCount']
              as num?)
          ?.toInt() ??
      -1;

  /// Native drift samples recorded count.
  int get driftNativeSamplesRecorded =>
      (metrics['driftNativeSamplesRecorded'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftNativeSamplesRecorded']
              as num?)
          ?.toInt() ??
      -1;

  /// Native drift samples rejected count.
  int get driftNativeSamplesRejected =>
      (metrics['driftNativeSamplesRejected'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['driftNativeSamplesRejected']
              as num?)
          ?.toInt() ??
      -1;

  // ---- Stale Probe Getters (Y16) ------------------------------------------

  /// Whether deliberate stale probe was attempted.
  bool get staleProbeAttempted =>
      metrics['staleProbeAttempted'] == true ||
      (metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
              as Map?)?['staleProbeAttempted'] ==
          true;

  /// Return value of postDriftSample for stale probe.
  bool get staleProbePostReturn =>
      metrics['staleProbePostReturn'] == true ||
      (metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
              as Map?)?['staleProbePostReturn'] ==
          true;

  /// Stale probe callback invocation count.
  int get staleProbeCallbackCount =>
      (metrics['staleProbeCallbackCount'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['staleProbeCallbackCount']
              as num?)
          ?.toInt() ??
      -1;

  /// Stale probe stale rejected count.
  int get staleProbeStaleRejectedCount =>
      (metrics['staleProbeStaleRejectedCount'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['staleProbeStaleRejectedCount']
              as num?)
          ?.toInt() ??
      -1;

  /// Stale probe reject reason token.
  String get staleProbeReason =>
      metrics['staleProbeReason']?.toString() ??
      (metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
              as Map?)?['staleProbeReason']
          ?.toString() ??
      '';

  /// Whether stale probe was accepted.
  bool get staleProbeAccepted =>
      metrics['staleProbeAccepted'] == true ||
      (metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
              as Map?)?['staleProbeAccepted'] ==
          true;

  /// Native recorded drift samples before stale probe.
  int get staleProbeNativeRecordedBefore =>
      (metrics['staleProbeNativeRecordedBefore'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['staleProbeNativeRecordedBefore']
              as num?)
          ?.toInt() ??
      -1;

  /// Native recorded drift samples after stale probe.
  int get staleProbeNativeRecordedAfter =>
      (metrics['staleProbeNativeRecordedAfter'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['staleProbeNativeRecordedAfter']
              as num?)
          ?.toInt() ??
      -1;

  /// Native sample count before stale probe.
  int get staleProbeNativeCountBefore =>
      (metrics['staleProbeNativeCountBefore'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['staleProbeNativeCountBefore']
              as num?)
          ?.toInt() ??
      -1;

  /// Native sample count after stale probe.
  int get staleProbeNativeCountAfter =>
      (metrics['staleProbeNativeCountAfter'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['staleProbeNativeCountAfter']
              as num?)
          ?.toInt() ??
      -1;

  /// Transport commandsIssued before stale probe.
  int get staleProbeCommandsBefore =>
      (metrics['staleProbeCommandsBefore'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['staleProbeCommandsBefore']
              as num?)
          ?.toInt() ??
      -1;

  /// Transport commandsIssued after stale probe.
  int get staleProbeCommandsAfter =>
      (metrics['staleProbeCommandsAfter'] as num?)?.toInt() ??
      ((metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
                  as Map?)?['staleProbeCommandsAfter']
              as num?)
          ?.toInt() ??
      -1;

  /// State machine state name before stale probe.
  String get staleProbeStateBefore =>
      metrics['staleProbeStateBefore']?.toString() ??
      (metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
              as Map?)?['staleProbeStateBefore']
          ?.toString() ??
      '';

  /// State machine state name after stale probe.
  String get staleProbeStateAfter =>
      metrics['staleProbeStateAfter']?.toString() ??
      (metrics['SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE']
              as Map?)?['staleProbeStateAfter']
          ?.toString() ??
      '';
}
