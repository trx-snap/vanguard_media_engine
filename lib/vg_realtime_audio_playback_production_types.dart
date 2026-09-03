// vg_realtime_audio_playback_production_types.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK (Y8a) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-DEAD-OBJECT (Y8b) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SEEK (Y9) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-REPEATED-SEEK (Y10b) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-FOCUS-RESPONSE (Y11b) +
// P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-ROUTE-CHANGE (Y12): Android True-DAG Phase 4
// realtime audio playback production sink, clock, dead-object, forward-seek, repeated-seek, focus response, and route-change diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimeAudioPlaybackProductionSmoke` MethodChannel route.
// Diagnostic-only - drives the production VanguardRealtimeAudioPlaybackSession
// (real MediaExtractor / MediaCodec -> Y5a external ingest -> Y1 transport ->
// sink-thread-owned non-zero-gain AudioTrack + presentation clock) through ten
// scenarios:
//   1. Playthrough + bounded pause/resume to EOS.
//   2. Mid-playback stop/dispose verifying clean release.
//   3. Synthetic dead-object recovery to EOS.
//   4. Forward mid-stream seek while paused to EOS.
//   5. Repeated forward seek while paused (T1 then T2, third seek rejected) to EOS.
//   6. Focus duck, restore, transient pause, auto-resume, and noisy terminal pause.
//   7. Focus permanent loss terminal pause without auto-resume.
//   8. Route change observation without transport mutation (independently bounded; no disconnect posted).
//   9. Route disconnect terminal pause, public resume blocked, and routing teardown (independently bounded, fresh PLAYING session).
//  10. Route disconnect while paused by focus policy: public resume blocked and focus auto-resume blocked.
//
// Required proof lanes (42 native lanes plus canonical equals 43 total lanes):
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
//  32. focusSetupOk: focus request and noisy receiver registered, monitor started
//  33. focusDuckRestoreOk: transient duck gain and full restore applied on sink thread
//  34. focusTransientPauseResumeOk: transient loss pauses transport, subsequent gain auto-resumes
//  35. focusNoisyTerminalPauseOk: noisy event triggers terminal pause, subsequent gain ignored
//  36. focusPermanentLossPauseOk: permanent loss triggers terminal pause, subsequent gain ignored
//  37. focusMonitorTeardownOk: focus monitor thread exited/joined and controller released cleanly
//  38. routingSetupOk: routing controller attached and monitor thread started cleanly
//  39. routeChangeObservationOk: route change observed without mutating transport state
//  40. routeDisconnectTerminalPauseOk: route disconnect triggers terminal pause with AudioTrack paused at park
//  41. routeDisconnectResumeBlockedOk: public resume rejected and subsequent focus gain does not auto-resume
//  42. routingMonitorTeardownOk: routing controller released, monitor thread exited and joined cleanly
//  (canonical: aggregate pass evaluation holding across all required lanes)
//
// Honest non-claims (Proof Boundary):
// production_engine_component_diagnostic_route_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_sink_thread_owned_audiotrack_and_presentation_clock_bounded_pause_resume_closes_reopens_clock_epoch_at_last_published_position_synthetic_armed_dead_object_recovered_once_on_sink_thread_same_parameter_audiotrack_epoch_rebase_real_or_repeated_dead_object_fails_closed_one_forward_mid_stream_seek_while_paused_feed_held_at_window_aligned_anchor_quiescent_audiotrack_flush_once_on_sink_thread_before_transport_seek_seek_clock_epoch_based_at_target_deliberate_discontinuity_stale_generation_rejected_before_jni_two_ordered_forward_seeks_and_third_rejected_without_teardown_production_focus_response_focus_monitor_single_consumer_audiomanager_focus_request_becoming_noisy_receiver_sink_thread_gain_duck_restore_request_ack_transient_pause_auto_resume_user_intent_gated_noisy_terminal_pause_no_auto_resume_permanent_loss_pause_no_auto_resume_production_route_change_response_routing_monitor_single_consumer_audiotrack_routing_listener_attach_detach_route_change_observed_no_transport_mutation_route_disconnect_terminal_pause_no_resume_focus_gain_after_route_disconnect_no_auto_resume_stop_dispose_release_once_no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_no_jni
//
// Honest operational non-claims:
//   - Synthetic recovery is not gapless; up to one AudioTrack client buffer plus
//     one mix window of already-written content may be discarded with the dead
//     instance.
//   - 300 ms publication lag is device observability budget, not latency/SLA.
//   - Checksum identity is over frames handed to write, not frames audibly presented.
//   - Forward seek exercises ONE forward seek while paused; repeated seek exercises
//     two ordered forward seeks while paused and verifies third rejected without teardown.
//   - Audio focus proof operates on synthetic focus change / becoming noisy seams without
//     requiring real OS phone calls or bluetooth events during headless diagnostic runs.
//   - Route change and route disconnect proof operates on synthetic route change / disconnect seams without
//     requiring real OS bluetooth or headphone events during headless diagnostic runs.

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
      'production_engine_component_diagnostic_route_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_sink_thread_owned_audiotrack_and_presentation_clock_bounded_pause_resume_closes_reopens_clock_epoch_at_last_published_position_synthetic_armed_dead_object_recovered_once_on_sink_thread_same_parameter_audiotrack_epoch_rebase_real_or_repeated_dead_object_fails_closed_one_forward_mid_stream_seek_while_paused_feed_held_at_window_aligned_anchor_quiescent_audiotrack_flush_once_on_sink_thread_before_transport_seek_seek_clock_epoch_based_at_target_deliberate_discontinuity_stale_generation_rejected_before_jni_two_ordered_forward_seeks_and_third_rejected_without_teardown_production_focus_response_focus_monitor_single_consumer_audiomanager_focus_request_becoming_noisy_receiver_sink_thread_gain_duck_restore_request_ack_transient_pause_auto_resume_user_intent_gated_noisy_terminal_pause_no_auto_resume_permanent_loss_pause_no_auto_resume_production_route_change_response_routing_monitor_single_consumer_audiotrack_routing_listener_attach_detach_route_change_observed_no_transport_mutation_route_disconnect_terminal_pause_no_resume_focus_gain_after_route_disconnect_no_auto_resume_stop_dispose_release_once_no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_no_jni';

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
      routingMonitorTeardownOk;

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
        routingMonitorTeardownOk;

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
}
