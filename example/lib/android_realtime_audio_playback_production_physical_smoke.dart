// android_realtime_audio_playback_production_physical_smoke.dart
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
// P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER-RING-PAUSE-RESUME (Y19): Android True-DAG Phase 4
// realtime audio playback production sink, clock, dead-object, forward-seek, repeated-seek, focus response, route-change, presentation-clock, position query lifecycle, clock correlation, drift sample ownership, ring frame source, real-decoder ring frame source, and real-decoder ring pause/resume diagnostic physical smoke target.
//
// Component diagnostic smoke: drives production VanguardRealtimeAudioPlaybackSession
// (real MediaExtractor / MediaCodec -> Y5a external ingest -> Y1 transport ->
// sink-thread-owned non-zero-gain AudioTrack + presentation clock).
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
//
// This is a component diagnostic smoke. It must not claim
// product/editor/UI/ConnectsApp/iOS/streaming/cache/audio clock mutator changes/clock feedback proof.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  if (!Platform.isAndroid) {
    print(
      'FAIL: android_realtime_audio_playback_production_physical_smoke is Android-only. Current OS: ${Platform.operatingSystem}',
    );
    print(VGRealtimeAudioPlaybackProductionSmokeReport.failMarkerConstant);
    exit(1);
  }

  runApp(const AndroidRealtimeAudioPlaybackProductionPhysicalSmokeApp());
}

class AndroidRealtimeAudioPlaybackProductionPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimeAudioPlaybackProductionPhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimeAudioPlaybackProductionPhysicalSmokeApp> createState() =>
      _AndroidRealtimeAudioPlaybackProductionPhysicalSmokeAppState();
}

class _AndroidRealtimeAudioPlaybackProductionPhysicalSmokeAppState
    extends State<AndroidRealtimeAudioPlaybackProductionPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 (Y8a/Y8b/Y9/Y10b/Y11b/Y12/Y13/Y14/Y15/Y16) Realtime Audio Playback Production Sink, Clock, Dead-Object, Seek, Repeated-Seek, Focus Response, Route-Change, Presentation-Clock, Position-Query, Clock Correlation & Drift Sample Ownership smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // Print START marker before calling wrapper as required by contract.
    print(VGRealtimeAudioPlaybackProductionSmokeReport.startMarkerConstant);

    VGRealtimeAudioPlaybackProductionSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;
    String? selectedFixturePath;

    final candidates = <String>[
      'assets/manual_test_clips/clip_B.mov',
      'assets/manual_test_clips/clip_A.mov',
      'assets/manual_test_clips/clip_A.mp3',
    ];

    try {
      // 1. Choose first available fixture.
      for (final candidate in candidates) {
        ByteData? assetData;
        try {
          assetData = await rootBundle.load(candidate);
        } catch (_) {
          final directFile = File(candidate);
          if (directFile.existsSync()) {
            final bytes = await directFile.readAsBytes();
            assetData = ByteData.view(bytes.buffer);
          }
        }

        if (assetData == null) {
          print('  [CANDIDATE_SKIP] Fixture not found: $candidate');
          continue;
        }

        final ext = candidate.endsWith('.mp3') ? 'mp3' : 'mov';
        final tempDir = Directory.systemTemp;
        final timestamp = DateTime.now().microsecondsSinceEpoch;
        final targetFile = File(
          '${tempDir.path}/p4_y11b_realtime_audio_playback_production_source_$timestamp.$ext',
        );

        await targetFile.writeAsBytes(
          assetData.buffer.asUint8List(
            assetData.offsetInBytes,
            assetData.lengthInBytes,
          ),
          flush: true,
        );

        tempSourceFile = targetFile;
        selectedFixturePath = tempSourceFile.path;
        print(
          '  [FIXTURE] Selected fixture: $candidate extracted to $selectedFixturePath',
        );
        break;
      }

      if (tempSourceFile == null || selectedFixturePath == null) {
        throw StateError(
          'No available fixture found from candidates: ${candidates.join(', ')}',
        );
      }

      // Print selected fixture path as required by contract.
      print('Selected fixture path: $selectedFixturePath');

      // 2. Invoke wrapper over production component diagnostic route.
      const physicalSmokeTimeout = Duration(seconds: 180);
      report =
          await VGRealtimeAudioPlaybackProductionSmokeReport.runRealtimeAudioPlaybackProductionSmoke(
            sourcePath: selectedFixturePath,
            maxDurationSec: 3.0,
            maxFramesPerMix: 256,
            gain: 0.5,
            deadlineMs: 30000,
            pauseHoldMs: 400,
            stopAfterMs: 300,
            deadObjectInjectAfterFrames: 8192,
            seekTargetSec: 1.0,
            secondSeekTargetSec: 2.0,
            preSeekHoldWindows: 64,
            maxSeekHoldMs: 15000,
            duckGain: 0.1,
            timeout: physicalSmokeTimeout,
          );
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_ERROR: $topLevelError',
      );
    } finally {
      if (tempSourceFile != null) {
        try {
          if (await tempSourceFile.exists()) {
            await tempSourceFile.delete();
            print(
              '  [CLEANUP] Deleted temp source file: ${tempSourceFile.path}',
            );
          }
        } catch (cleanupErr) {
          print(
            '  [CLEANUP_WARN] Failed to delete temp source file: $cleanupErr',
          );
        }
      }
    }

    final activeReport =
        report ??
        VGRealtimeAudioPlaybackProductionSmokeReport.fromMap(<String, Object?>{
          'pass': false,
          'status': 'fail',
          'marker':
              VGRealtimeAudioPlaybackProductionSmokeReport.failMarkerConstant,
          'failureReason': topLevelError ?? 'invocation_failed',
        });

    // 3. Print every lane needed for human/Codex review.
    print('--- LANES ---');
    print('  [LANE] formatProbeOk: ${activeReport.formatProbeOk}');
    print('  [LANE] preRollOk: ${activeReport.preRollOk}');
    print('  [LANE] startOk: ${activeReport.startOk}');
    print(
      '  [LANE] nonZeroGainAudioTrackOk: ${activeReport.nonZeroGainAudioTrackOk}',
    );
    print(
      '  [LANE] playthroughAccountingOk: ${activeReport.playthroughAccountingOk}',
    );
    print('  [LANE] checksumIdentityOk: ${activeReport.checksumIdentityOk}');
    print('  [LANE] clockAnchoredOk: ${activeReport.clockAnchoredOk}');
    print('  [LANE] clockMonotonicOk: ${activeReport.clockMonotonicOk}');
    print(
      '  [LANE] clockEpochBalancedOk: ${activeReport.clockEpochBalancedOk}',
    );
    print('  [LANE] clockPauseFrozenOk: ${activeReport.clockPauseFrozenOk}');
    print(
      '  [LANE] boundedPauseResumeOk: ${activeReport.boundedPauseResumeOk}',
    );
    print('  [LANE] stopDisposeOk: ${activeReport.stopDisposeOk}');
    print(
      '  [LANE] decoderCancelledOnStopOk: ${activeReport.decoderCancelledOnStopOk}',
    );
    print('  [LANE] transportDisposedOk: ${activeReport.transportDisposedOk}');
    print(
      '  [LANE] audioTrackReleasedOnceOk: ${activeReport.audioTrackReleasedOnceOk}',
    );
    print('  [LANE] threadOwnershipOk: ${activeReport.threadOwnershipOk}');
    print('  [LANE] noFeedbackOk: ${activeReport.noFeedbackOk}');
    print('  [LANE] proofBoundaryOk: ${activeReport.proofBoundaryOk}');
    print(
      '  [LANE] syntheticDeadObjectRecoveryOk: ${activeReport.syntheticDeadObjectRecoveryOk}',
    );
    print(
      '  [LANE] deadObjectClockEpochRebaseOk: ${activeReport.deadObjectClockEpochRebaseOk}',
    );
    print(
      '  [LANE] deadObjectRemainderAccountingOk: ${activeReport.deadObjectRemainderAccountingOk}',
    );
    print(
      '  [LANE] seekQuiesceAccountingOk: ${activeReport.seekQuiesceAccountingOk}',
    );
    print('  [LANE] seekCommandOk: ${activeReport.seekCommandOk}');
    print('  [LANE] sinkFlushAtSeekOk: ${activeReport.sinkFlushAtSeekOk}');
    print(
      '  [LANE] decoderSeekReanchorOk: ${activeReport.decoderSeekReanchorOk}',
    );
    print(
      '  [LANE] staleGenerationRejectedOk: ${activeReport.staleGenerationRejectedOk}',
    );
    print('  [LANE] seekClockEpochOk: ${activeReport.seekClockEpochOk}');
    print('  [LANE] postSeekDrainOk: ${activeReport.postSeekDrainOk}');
    print(
      '  [LANE] repeatedSeekCommandOk: ${activeReport.repeatedSeekCommandOk}',
    );
    print(
      '  [LANE] repeatedSeekCumulativeAccountingOk: ${activeReport.repeatedSeekCumulativeAccountingOk}',
    );
    print(
      '  [LANE] repeatedSeekThirdRejectOk: ${activeReport.repeatedSeekThirdRejectOk}',
    );
    print('  [LANE] focusSetupOk: ${activeReport.focusSetupOk}');
    print('  [LANE] focusDuckRestoreOk: ${activeReport.focusDuckRestoreOk}');
    print(
      '  [LANE] focusTransientPauseResumeOk: ${activeReport.focusTransientPauseResumeOk}',
    );
    print(
      '  [LANE] focusNoisyTerminalPauseOk: ${activeReport.focusNoisyTerminalPauseOk}',
    );
    print(
      '  [LANE] focusPermanentLossPauseOk: ${activeReport.focusPermanentLossPauseOk}',
    );
    print(
      '  [LANE] focusMonitorTeardownOk: ${activeReport.focusMonitorTeardownOk}',
    );
    print('  [LANE] routingSetupOk: ${activeReport.routingSetupOk}');
    print(
      '  [LANE] routeChangeObservationOk: ${activeReport.routeChangeObservationOk}',
    );
    print(
      '  [LANE] routeDisconnectTerminalPauseOk: ${activeReport.routeDisconnectTerminalPauseOk}',
    );
    print(
      '  [LANE] routeDisconnectResumeBlockedOk: ${activeReport.routeDisconnectResumeBlockedOk}',
    );
    print(
      '  [LANE] routingMonitorTeardownOk: ${activeReport.routingMonitorTeardownOk}',
    );
    print(
      '  [LANE] currentPositionQuerySurfaceOk: ${activeReport.currentPositionQuerySurfaceOk}',
    );
    print(
      '  [LANE] currentPositionPollerMonotonicOk: ${activeReport.currentPositionPollerMonotonicOk}',
    );
    print(
      '  [LANE] currentPositionReadCounterIsolationOk: ${activeReport.currentPositionReadCounterIsolationOk}',
    );
    print(
      '  [LANE] presentationLagTelemetryOk: ${activeReport.presentationLagTelemetryOk}',
    );
    print(
      '  [LANE] presentationLagBoundedOk: ${activeReport.presentationLagBoundedOk}',
    );
    print(
      '  [LANE] positionAtEosNoRunawayOk: ${activeReport.positionAtEosNoRunawayOk}',
    );
    print(
      '  [LANE] positionQueryPauseHoldFrozenOk: ${activeReport.positionQueryPauseHoldFrozenOk}',
    );
    print(
      '  [LANE] positionQueryDeadObjectRebaseOk: ${activeReport.positionQueryDeadObjectRebaseOk}',
    );
    print(
      '  [LANE] positionQuerySeekBaseAdvanceOk: ${activeReport.positionQuerySeekBaseAdvanceOk}',
    );
    print(
      '  [LANE] positionQueryRepeatedSeekBaseAdvanceOk: ${activeReport.positionQueryRepeatedSeekBaseAdvanceOk}',
    );
    print(
      '  [LANE] positionQueryPostTeardownLatchedOk: ${activeReport.positionQueryPostTeardownLatchedOk}',
    );
    print(
      '  [LANE] nativeAudioClockSnapshotPublishedOk: ${activeReport.nativeAudioClockSnapshotPublishedOk}',
    );
    print(
      '  [LANE] clockCorrelationTelemetryOk: ${activeReport.clockCorrelationTelemetryOk}',
    );
    print(
      '  [LANE] clockObservationNoFeedbackOk: ${activeReport.clockObservationNoFeedbackOk}',
    );
    print(
      '  [LANE] driftSampleWorkerOwnedOk: ${activeReport.driftSampleWorkerOwnedOk}',
    );
    print(
      '  [LANE] driftSampleGenerationPinnedOk: ${activeReport.driftSampleGenerationPinnedOk}',
    );
    print(
      '  [LANE] driftSampleNoFeedbackOk: ${activeReport.driftSampleNoFeedbackOk}',
    );
    print(
      '  [LANE] clockAuthorityUnchangedOk: ${activeReport.clockAuthorityUnchangedOk}',
    );
    print('  [LANE] ringFrameSourceOk: ${activeReport.ringFrameSourceOk}');
    print(
      '  [LANE] realDecoderRingFrameSourceOk: ${activeReport.realDecoderRingFrameSourceOk}',
    );
    print('  [LANE] realRingPauseAckOk: ${activeReport.realRingPauseAckOk}');
    print(
      '  [LANE] realRingPauseHoldFrozenOk: ${activeReport.realRingPauseHoldFrozenOk}',
    );
    print('  [LANE] realRingResumeAckOk: ${activeReport.realRingResumeAckOk}');
    print(
      '  [LANE] realRingPostResumeChecksumOk: ${activeReport.realRingPostResumeChecksumOk}',
    );
    print('  [LANE] canonical: ${activeReport.canonical}');

    // 4. Print key metrics needed for human/Codex review.
    Map<String, Object?> asStringKeyedMap(Object? raw) {
      if (raw is Map) {
        return raw.map((k, v) => MapEntry(k.toString(), v));
      }
      return const <String, Object?>{};
    }

    const playthroughScenarioKey = 'PLAYTHROUGH_BOUNDED_PAUSE_RESUME_TO_EOS';
    const stopDisposeScenarioKey = 'STOP_DISPOSE_MID_PLAYBACK';
    const deadObjectScenarioKey = 'SYNTHETIC_DEAD_OBJECT_RECOVERY_TO_EOS';
    const forwardSeekScenarioKey = 'SCENARIO_FORWARD_SEEK_TO_EOS';
    const repeatedSeekScenarioKey = 'SCENARIO_REPEATED_FORWARD_SEEK_TO_EOS';
    const backwardSeekScenarioKey = 'SCENARIO_BACKWARD_SEEK_TO_EOS';
    const focusDuckTransientNoisyScenarioKey =
        'SCENARIO_FOCUS_DUCK_TRANSIENT_NOISY';
    const focusPermanentLossScenarioKey = 'SCENARIO_FOCUS_PERMANENT_LOSS';
    const routeChangeObservationScenarioKey =
        'SCENARIO_ROUTE_CHANGE_OBSERVATION';
    const routeDisconnectTerminalPauseScenarioKey =
        'SCENARIO_ROUTE_DISCONNECT_TERMINAL_PAUSE';
    const routeDisconnectFocusGainBlockedScenarioKey =
        'SCENARIO_ROUTE_DISCONNECT_FOCUS_GAIN_BLOCKED';
    const presentationClockQuerySurfaceScenarioKey =
        'SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE';
    const ringFrameSourceScenarioKey = 'SCENARIO_RING_FRAME_SOURCE_TO_EOS';
    const realDecoderRingFrameSourceScenarioKey =
        'SCENARIO_REAL_DECODER_RING_FRAME_SOURCE_TO_EOS';
    const realRingPauseResumeScenarioKey =
        'SCENARIO_REAL_DECODER_RING_PAUSE_RESUME_TO_EOS';

    final topMetrics = activeReport.metrics;
    final playthroughMetrics = asStringKeyedMap(
      topMetrics[playthroughScenarioKey],
    );
    final stopDisposeMetrics = asStringKeyedMap(
      topMetrics[stopDisposeScenarioKey],
    );
    final deadObjectMetrics = asStringKeyedMap(
      topMetrics[deadObjectScenarioKey],
    );
    final forwardSeekMetrics = asStringKeyedMap(
      topMetrics[forwardSeekScenarioKey],
    );
    final repeatedSeekMetrics = asStringKeyedMap(
      topMetrics[repeatedSeekScenarioKey],
    );
    final backwardSeekMetrics = asStringKeyedMap(
      topMetrics[backwardSeekScenarioKey],
    );
    final focusDuckTransientNoisyMetrics = asStringKeyedMap(
      topMetrics[focusDuckTransientNoisyScenarioKey],
    );
    final focusPermanentLossMetrics = asStringKeyedMap(
      topMetrics[focusPermanentLossScenarioKey],
    );
    final routeChangeObservationMetrics = asStringKeyedMap(
      topMetrics[routeChangeObservationScenarioKey],
    );
    final routeDisconnectTerminalPauseMetrics = asStringKeyedMap(
      topMetrics[routeDisconnectTerminalPauseScenarioKey],
    );
    final routeDisconnectFocusGainBlockedMetrics = asStringKeyedMap(
      topMetrics[routeDisconnectFocusGainBlockedScenarioKey],
    );
    final presentationClockQuerySurfaceMetrics = asStringKeyedMap(
      topMetrics[presentationClockQuerySurfaceScenarioKey],
    );
    final ringFrameSourceMetrics = asStringKeyedMap(
      topMetrics[ringFrameSourceScenarioKey],
    );
    final realDecoderRingFrameSourceMetrics = asStringKeyedMap(
      topMetrics[realDecoderRingFrameSourceScenarioKey],
    );
    final realRingPauseResumeMetrics = asStringKeyedMap(
      topMetrics[realRingPauseResumeScenarioKey],
    );

    const deadObjectScenarioOwnedKeys = <String>{
      'syntheticDeadObjectInjectAfterFrames',
      'deadObjectInjectedCount',
      'deadObjectObservedCount',
      'deadObjectRecoveryCount',
      'deadObjectOldTrackReleaseCount',
      'deadObjectRecoveryExecutedOnSinkThread',
      'deadObjectNewTrackInitOk',
      'deadObjectNewTrackVolumeOk',
      'deadObjectNewTrackPlayOk',
      'deadObjectNewTrackPlayState',
      'deadObjectNewTrackSameBuffer',
      'deadObjectNewTrackBufferFrames',
      'deadObjectRecoveryWallMs',
      'deadObjectEpochBeforeRecovery',
      'deadObjectEpochOpenedAfterRecovery',
      'deadObjectEpochCloseAccepted',
      'deadObjectEpochOpenAccepted',
      'deadObjectPositionBeforeRecovery',
      'deadObjectBaseFrameAfterRecovery',
      'deadObjectBaseStepFrames',
      'deadObjectBaseStepBounded',
      'deadObjectContentHeadAtDeadObject',
      'deadObjectWrittenAheadOfHeadFrames',
      'deadObjectPublicationLagFrames',
      'deadObjectBaseStepDecompositionOk',
      'deadObjectClockProvenanceAtRecovery',
      'deadObjectClockLastAgeNsAtRecovery',
      'deadObjectSliceBytesAtRecovery',
      'deadObjectUnwrittenBytesAtRecovery',
      'deadObjectBufferPositionAtRecovery',
      'deadObjectFramesReadAtRecovery',
      'deadObjectFramesWrittenBeforeRecovery',
      'deadObjectRemainderFramesExpected',
      'deadObjectRemainderFramesWrittenOnNewTrack',
      'deadObjectRemainderAccountingOk',
      'deadObjectTimestampPollsDuringRecovery',
      'sinkClockSnapshotsAtDeadObjectRecovery',
      'playbackHeadAtDeadObject',
    };

    const forwardSeekScenarioOwnedKeys = <String>{
      'seekTargetSecArmed',
      'seekTargetFrame',
      'preSeekHoldFrame',
      'seekAdmissionOk',
      'seekHoldPinned',
      'seekCount',
      'seekAccepted',
      'seekStaleGeneration',
      'seekGeneration',
      'seekPauseAccepted',
      'seekPauseGeneration',
      'seekResumeAccepted',
      'seekResumeGeneration',
      'seekQuiesceFeedHeld',
      'seekQuiesceSinkReadFrames',
      'seekQuiesceSinkWrittenFrames',
      'seekQuiesceAccountingOk',
      'seekFlushRequestedWhilePaused',
      'seekFlushAckedBeforeSeek',
      'sinkFlushRequestCount',
      'sinkFlushCount',
      'sinkFlushExecutedOnSinkThread',
      'sinkSeekParkCount',
      'sinkSeekTargetFrame',
      'sinkSeekEpochOpenedAtUnpark',
      'sinkSeekEpochBaseFrame',
      'sinkSeekDiscontinuityFrames',
      'sinkSeekEpochOpenAccepted',
      'decoderHoldFrame',
      'decoderHeldAtHoldFrame',
      'decoderAnchorFrame',
      'decoderSeekReanchorCount',
      'decoderReanchorOk',
      'decoderReanchorExecutedOnDecodeThread',
      'decoderPreSeekAcceptedFrames',
      'decoderSeekTargetFrame',
      'decoderStaleProbeCalls',
      'decoderStaleProbeRejected',
      'decoderStaleProbeReplyNull',
      'decoderStaleProbeAnchorUntouched',
      'decoderPostSeekAcceptedFrames',
      'expectedTotalFrames',
      'postSeekExpectedFrames',
      'decoderLandingOk',
      'decoderGapPolicyOk',
    };

    const repeatedSeekScenarioOwnedKeys = <String>{
      'secondSeekTargetSec',
      'secondSeekTargetSecArmed',
      'target1Frame',
      'target2Frame',
      'hold1Frame',
      'hold2Frame',
      'sinkHold2Frame',
      'thirdSeekCount',
      'finalSeekCount',
      'afterFirstSeekState',
      'afterSecondSeekState',
      'afterThirdSeekState',
      'afterThirdSeekTransportState',
    };

    const focusScenarioOwnedKeys = <String>{
      'focusEnabled',
      'focusControllerRequested',
      'focusControllerGranted',
      'focusControllerNoisyRegistered',
      'focusControllerReleased',
      'focusMonitorStarted',
      'focusMonitorExited',
      'focusMonitorJoined',
      'focusMonitorThreadId',
      'focusEventsDrained',
      'focusDuckAppliedCount',
      'focusGainRestoreAppliedCount',
      'focusPauseTransientAppliedCount',
      'focusPauseNoisyAppliedCount',
      'focusPausePermanentAppliedCount',
      'focusAutoResumeAppliedCount',
      'ignoredGainEventsDrained',
      'ignoredGainRestoreAppliedCount',
      'ignoredGainAutoResumeCount',
      'focusState',
      'focusTerminalNoisyLoss',
      'focusTerminalPermanentLoss',
      'sinkEffectiveGain',
      'afterDuckGain',
      'afterRestoreGain',
      'duckGain',
    };

    const routingScenarioOwnedKeys = <String>{
      'routingEnabled',
      'routingControllerAttached',
      'routingControllerReleased',
      'routingAttachCount',
      'routingDetachCount',
      'routingLastAttachError',
      'routingLastDetachError',
      'routingMonitorStarted',
      'routingMonitorExited',
      'routingMonitorJoined',
      'routingMonitorThreadId',
      'routingEventsEnqueued',
      'routingEventsDrained',
      'routingEventsDropped',
      'routingEventsPending',
      'routeChangedAppliedCount',
      'routeDisconnectAppliedCount',
      'routingTerminalDisconnect',
      'routingPausedByPolicy',
      'routingLastEventTag',
      'routingLastEventSeq',
      'routingLastEventSource',
      'routingLastAction',
      'routingLastReason',
      'publicResumeAccepted',
      'publicResumeReason',
      'afterRejectedResumeState',
    };

    bool isFocusPermanentLossMetric(String key) {
      return key == 'focusPausePermanentAppliedCount' ||
          key == 'focusTerminalPermanentLoss';
    }

    bool isFocusOwnedMetric(String key) {
      return key.startsWith('focus') ||
          key.startsWith('ignoredGain') ||
          focusScenarioOwnedKeys.contains(key);
    }

    bool isRoutingOwnedMetric(String key) {
      return key.startsWith('routing') ||
          key.startsWith('route') ||
          routingScenarioOwnedKeys.contains(key);
    }

    bool isDeadObjectOwnedMetric(String key) {
      return key.startsWith('deadObject') ||
          deadObjectScenarioOwnedKeys.contains(key);
    }

    bool isForwardSeekOwnedMetric(String key) {
      return (key.startsWith('seek') &&
              !key.startsWith('secondSeek') &&
              key != 'secondSeekTargetSecArmed') ||
          key.startsWith('decoderSeek') ||
          key.startsWith('sinkSeek') ||
          forwardSeekScenarioOwnedKeys.contains(key);
    }

    bool isRepeatedSeekOwnedMetric(String key) {
      return key.startsWith('secondSeek') ||
          repeatedSeekScenarioOwnedKeys.contains(key);
    }

    const presentationClockScenarioOwnedKeys = <String>{
      'pollerPollCount',
      'pollerValidCount',
      'pollerRegressionCount',
      'pollerFrameReadCount',
      'pollerUsReadCount',
      'pollerLastFrame',
      'pollerLastUs',
      'pollerMinFrame',
      'pollerMaxFrame',
      'pollerMinUs',
      'pollerMaxUs',
      'pollerThreadId',
      'pollerJoined',
      'pollerError',
      'presentationLagSampleCount',
      'presentationLagBoundedSampleCount',
      'presentationLagExcludedSampleCount',
      'lastPresentationLagFrames',
      'minPresentationLagFrames',
      'maxPresentationLagFrames',
      'presentationLagLowerBoundFrames',
      'presentationLagUpperBoundFrames',
      'lastPositionFramesAtPoll',
      'lastPositionUsAtPoll',
      'positionAtEosFrames',
      'positionAtEosUs',
      'currentPositionReadsFromWriterThread',
      'currentPositionReadsFromOtherThreads',
      'nativeClockState',
      'nativeClockPositionUs',
      'nativeClockPositionFrame',
      'nativeClockDriftSampleCount',
      'presentationClockPositionUsAtCorrelation',
      'presentationClockPositionFramesAtCorrelation',
      'clockCorrelationOffsetUs',
      'clockCorrelationOffsetFrames',
      'clockCorrelationCommandsBefore',
      'clockCorrelationCommandsAfter',
    };

    bool isPresentationClockOwnedMetric(String key) {
      return key.startsWith('poller') ||
          key.startsWith('presentationLag') ||
          key.startsWith('currentPosition') ||
          key.startsWith('positionAtEos') ||
          presentationClockScenarioOwnedKeys.contains(key);
    }

    Object? lookupMetric(String key) {
      if (isPresentationClockOwnedMetric(key)) {
        return topMetrics[key] ??
            presentationClockQuerySurfaceMetrics[key] ??
            playthroughMetrics[key] ??
            stopDisposeMetrics[key] ??
            deadObjectMetrics[key] ??
            forwardSeekMetrics[key] ??
            repeatedSeekMetrics[key] ??
            focusDuckTransientNoisyMetrics[key] ??
            focusPermanentLossMetrics[key] ??
            routeChangeObservationMetrics[key] ??
            routeDisconnectTerminalPauseMetrics[key] ??
            routeDisconnectFocusGainBlockedMetrics[key];
      }
      if (isRoutingOwnedMetric(key)) {
        return topMetrics[key] ??
            routeChangeObservationMetrics[key] ??
            routeDisconnectTerminalPauseMetrics[key] ??
            routeDisconnectFocusGainBlockedMetrics[key] ??
            playthroughMetrics[key] ??
            stopDisposeMetrics[key] ??
            deadObjectMetrics[key] ??
            forwardSeekMetrics[key] ??
            repeatedSeekMetrics[key] ??
            focusDuckTransientNoisyMetrics[key] ??
            focusPermanentLossMetrics[key];
      }
      if (isFocusPermanentLossMetric(key)) {
        return topMetrics[key] ??
            focusPermanentLossMetrics[key] ??
            focusDuckTransientNoisyMetrics[key] ??
            routeDisconnectFocusGainBlockedMetrics[key] ??
            routeDisconnectTerminalPauseMetrics[key] ??
            routeChangeObservationMetrics[key];
      }
      if (isFocusOwnedMetric(key)) {
        return topMetrics[key] ??
            focusDuckTransientNoisyMetrics[key] ??
            focusPermanentLossMetrics[key] ??
            routeDisconnectFocusGainBlockedMetrics[key] ??
            routeDisconnectTerminalPauseMetrics[key] ??
            routeChangeObservationMetrics[key] ??
            playthroughMetrics[key] ??
            stopDisposeMetrics[key] ??
            deadObjectMetrics[key] ??
            forwardSeekMetrics[key] ??
            repeatedSeekMetrics[key];
      }
      if (isRepeatedSeekOwnedMetric(key)) {
        return repeatedSeekMetrics[key] ??
            topMetrics[key] ??
            forwardSeekMetrics[key] ??
            playthroughMetrics[key] ??
            stopDisposeMetrics[key] ??
            deadObjectMetrics[key] ??
            focusDuckTransientNoisyMetrics[key] ??
            focusPermanentLossMetrics[key] ??
            routeDisconnectTerminalPauseMetrics[key] ??
            routeChangeObservationMetrics[key];
      }
      if (isForwardSeekOwnedMetric(key)) {
        return forwardSeekMetrics[key] ??
            topMetrics[key] ??
            repeatedSeekMetrics[key] ??
            playthroughMetrics[key] ??
            stopDisposeMetrics[key] ??
            deadObjectMetrics[key] ??
            focusDuckTransientNoisyMetrics[key] ??
            focusPermanentLossMetrics[key] ??
            routeDisconnectTerminalPauseMetrics[key] ??
            routeChangeObservationMetrics[key];
      }
      if (isDeadObjectOwnedMetric(key)) {
        return deadObjectMetrics[key] ??
            playthroughMetrics[key] ??
            stopDisposeMetrics[key] ??
            forwardSeekMetrics[key] ??
            repeatedSeekMetrics[key] ??
            focusDuckTransientNoisyMetrics[key] ??
            focusPermanentLossMetrics[key] ??
            routeDisconnectTerminalPauseMetrics[key] ??
            routeChangeObservationMetrics[key] ??
            topMetrics[key];
      }
      return topMetrics[key] ??
          playthroughMetrics[key] ??
          stopDisposeMetrics[key] ??
          deadObjectMetrics[key] ??
          forwardSeekMetrics[key] ??
          repeatedSeekMetrics[key] ??
          focusDuckTransientNoisyMetrics[key] ??
          focusPermanentLossMetrics[key] ??
          routeDisconnectTerminalPauseMetrics[key] ??
          routeChangeObservationMetrics[key];
    }

    Map<String, Object?> extractCompactScenario(
      Map<String, Object?> source,
      List<String> keys,
    ) {
      final result = <String, Object?>{};
      for (final key in keys) {
        if (source.containsKey(key)) {
          result[key] = source[key];
        }
      }
      return result;
    }

    final compactPlaythrough =
        extractCompactScenario(playthroughMetrics, const <String>[
          'sourceMime',
          'sampleRate',
          'channelCount',
          'declaredFrameCount',
          'preRollFrames',
          'pauseHoldObservedMs',
          'decoderAcceptedFrames',
          'decoderPaddedFrames',
          'decoderChecksumHex',
          'decoderExitReason',
          'decoderMediaReleaseCount',
          'audioTrackReleaseCount',
          'framesReadFromTransport',
          'framesWrittenToSink',
          'sinkChecksumHex',
          'playbackHeadFinal',
          'nativePushedFrames',
          'nativeDrainedFrames',
          'nativeDiscardedFrames',
          'nativePushedChecksumHex',
          'nativeDrainedChecksumHex',
          'clockPositionFrames',
          'stateAtCompletion',
          'scenarioWallMs',
          'failureReason',
        ]);

    final compactStopDispose =
        extractCompactScenario(stopDisposeMetrics, const <String>[
          'declaredFrameCount',
          'decoderAcceptedFrames',
          'decoderChecksumHex',
          'decoderExitReason',
          'decoderMediaReleaseCount',
          'audioTrackReleaseCount',
          'framesWrittenBeforeStop',
          'framesWrittenToSink',
          'sinkChecksumHex',
          'stopAccepted',
          'stopReason',
          'stateAfterStop',
          'stateAfterDispose',
          'stateAfterSecondDispose',
          'scenarioWallMs',
          'failureReason',
        ]);

    final compactDeadObject =
        extractCompactScenario(deadObjectMetrics, const <String>[
          'audioTrackBufferFrames',
          'syntheticDeadObjectInjectAfterFrames',
          'deadObjectInjectedCount',
          'deadObjectObservedCount',
          'deadObjectRecoveryCount',
          'deadObjectOldTrackReleaseCount',
          'deadObjectRecoveryExecutedOnSinkThread',
          'deadObjectNewTrackInitOk',
          'deadObjectNewTrackVolumeOk',
          'deadObjectNewTrackPlayOk',
          'deadObjectNewTrackPlayState',
          'deadObjectNewTrackSameBuffer',
          'deadObjectNewTrackBufferFrames',
          'deadObjectRecoveryWallMs',
          'deadObjectEpochBeforeRecovery',
          'deadObjectEpochOpenedAfterRecovery',
          'deadObjectEpochCloseAccepted',
          'deadObjectEpochOpenAccepted',
          'deadObjectPositionBeforeRecovery',
          'deadObjectBaseFrameAfterRecovery',
          'deadObjectBaseStepFrames',
          'deadObjectBaseStepBounded',
          'deadObjectContentHeadAtDeadObject',
          'deadObjectWrittenAheadOfHeadFrames',
          'deadObjectPublicationLagFrames',
          'deadObjectBaseStepDecompositionOk',
          'deadObjectClockProvenanceAtRecovery',
          'deadObjectClockLastAgeNsAtRecovery',
          'deadObjectSliceBytesAtRecovery',
          'deadObjectUnwrittenBytesAtRecovery',
          'deadObjectBufferPositionAtRecovery',
          'deadObjectFramesReadAtRecovery',
          'deadObjectFramesWrittenBeforeRecovery',
          'deadObjectRemainderFramesExpected',
          'deadObjectRemainderFramesWrittenOnNewTrack',
          'deadObjectRemainderAccountingOk',
          'deadObjectTimestampPollsDuringRecovery',
          'sinkClockSnapshotsAtDeadObjectRecovery',
          'playbackHeadAtDeadObject',
          'stateAtCompletion',
          'scenarioWallMs',
          'failureReason',
        ]);

    final compactForwardSeek =
        extractCompactScenario(forwardSeekMetrics, const <String>[
          'seekTargetSecArmed',
          'seekTargetFrame',
          'preSeekHoldFrame',
          'seekAdmissionOk',
          'seekHoldPinned',
          'seekCount',
          'seekAccepted',
          'seekGeneration',
          'seekQuiesceAccountingOk',
          'seekFlushAckedBeforeSeek',
          'sinkFlushCount',
          'sinkFlushExecutedOnSinkThread',
          'sinkSeekParkCount',
          'sinkSeekEpochOpenedAtUnpark',
          'sinkSeekDiscontinuityFrames',
          'decoderReanchorOk',
          'decoderStaleProbeRejected',
          'expectedTotalFrames',
          'postSeekExpectedFrames',
          'decoderLandingOk',
          'decoderGapPolicyOk',
          'stateAtCompletion',
          'scenarioWallMs',
          'failureReason',
        ]);

    final compactRepeatedSeek =
        extractCompactScenario(repeatedSeekMetrics, const <String>[
          'seekTargetSecArmed',
          'secondSeekTargetSecArmed',
          'target1Frame',
          'target2Frame',
          'hold1Frame',
          'hold2Frame',
          'sinkHold2Frame',
          'expectedTotalFrames',
          'postSeekExpectedFrames',
          'afterFirstSeekState',
          'afterSecondSeekState',
          'afterThirdSeekState',
          'afterThirdSeekTransportState',
          'thirdSeekCount',
          'finalSeekCount',
          'decoderLandingOk',
          'decoderGapPolicyOk',
          'stateAtCompletion',
          'scenarioWallMs',
          'failureReason',
        ]);

    final compactBackwardSeek =
        extractCompactScenario(backwardSeekMetrics, const <String>[
          'seekTargetSecArmed',
          'seekBackwardArmed',
          'seekTargetFrame',
          'preSeekHoldFrame',
          'seekBackward',
          'seekDeclaredBackward',
          'sinkSeekDeclaredBackward',
          'sinkClockDeclaredBackwardOpenCalls',
          'seekClockDeclaredBackwardBaseCountAfterUnpark',
          'seekClockLastDeclaredBackwardFramesAfterUnpark',
          'decoderSeekBackward',
          'decoderSeekTargetUs',
          'decoderSeekLandedUs',
          'decoderFirstPostSeekPtsUs',
          'decoderFirstPostSeekFrame',
          'decoderGapObservedFrames',
          'decoderGapPaddedFrames',
          'decoderMaxSeekGapFrames',
          'decoderDiscardedPreTargetFrames',
          'decoderMaxPreTargetDiscardFrames',
          'expectedTotalFrames',
          'postSeekExpectedFrames',
          'afterSeekQueryFrames',
          'afterSeekState',
          'afterRepeatedState',
          'finalSeekCount',
          'decoderLandingOk',
          'decoderGapPolicyOk',
          'stateAtCompletion',
          'scenarioWallMs',
          'failureReason',
        ]);

    const focusCompactKeys = <String>[
      'focusEnabled',
      'focusControllerRequested',
      'focusControllerGranted',
      'focusControllerNoisyRegistered',
      'focusControllerReleased',
      'focusMonitorStarted',
      'focusMonitorExited',
      'focusMonitorJoined',
      'focusMonitorThreadId',
      'focusDuckAppliedCount',
      'focusGainRestoreAppliedCount',
      'focusPauseTransientAppliedCount',
      'focusPauseNoisyAppliedCount',
      'focusPausePermanentAppliedCount',
      'focusAutoResumeAppliedCount',
      'focusEventsDrained',
      'ignoredGainEventsDrained',
      'ignoredGainRestoreAppliedCount',
      'ignoredGainAutoResumeCount',
      'focusState',
      'focusTerminalNoisyLoss',
      'focusTerminalPermanentLoss',
      'sinkEffectiveGain',
      'afterDuckGain',
      'afterRestoreGain',
      'scenarioWallMs',
      'failureReason',
    ];

    final compactFocusDuckTransientNoisy = extractCompactScenario(
      focusDuckTransientNoisyMetrics,
      focusCompactKeys,
    );

    final compactFocusPermanentLoss = extractCompactScenario(
      focusPermanentLossMetrics,
      focusCompactKeys,
    );

    const routeChangeObservationCompactKeys = <String>[
      'routingEnabled',
      'routingControllerAttached',
      'routingControllerReleased',
      'routingAttachCount',
      'routingDetachCount',
      'routingMonitorStarted',
      'routingMonitorExited',
      'routingMonitorJoined',
      'routingMonitorThreadId',
      'routingEventsEnqueued',
      'routingEventsDrained',
      'routingEventsDropped',
      'routingEventsPending',
      'routeChangedAppliedBaseline',
      'routeChangedAppliedCount',
      'routeDisconnectAppliedCount',
      'routingTerminalDisconnect',
      'routingLastAction',
      'routingLastReason',
      'scenarioWallMs',
      'failureReason',
    ];

    final compactRouteChangeObservation = extractCompactScenario(
      routeChangeObservationMetrics,
      routeChangeObservationCompactKeys,
    );

    const routeDisconnectTerminalPauseCompactKeys = <String>[
      'routingEnabled',
      'routingControllerAttached',
      'routingControllerReleased',
      'routingAttachCount',
      'routingDetachCount',
      'routingMonitorStarted',
      'routingMonitorExited',
      'routingMonitorJoined',
      'routingMonitorThreadId',
      'routingEventsEnqueued',
      'routingEventsDrained',
      'routingEventsDropped',
      'routingEventsPending',
      'routeDisconnectAppliedBaseline',
      'routeDisconnectAppliedCount',
      'routingTerminalDisconnect',
      'routingPausedByPolicy',
      'routingLastAction',
      'routingLastReason',
      'publicResumeAccepted',
      'publicResumeReason',
      'afterRejectedResumeState',
      'scenarioWallMs',
      'failureReason',
    ];

    final compactRouteDisconnectTerminalPause = extractCompactScenario(
      routeDisconnectTerminalPauseMetrics,
      routeDisconnectTerminalPauseCompactKeys,
    );

    const routeFocusBlockedCompactKeys = <String>[
      'routingEnabled',
      'routingControllerAttached',
      'routingControllerReleased',
      'routingAttachCount',
      'routingDetachCount',
      'routingMonitorStarted',
      'routingMonitorExited',
      'routingMonitorJoined',
      'routingMonitorThreadId',
      'routingTerminalDisconnect',
      'routingLastEventTag',
      'routingLastAction',
      'pauseTransientAppliedCount',
      'focusPausedByPolicy',
      'ignoredGainEventsDrained',
      'ignoredGainRestoreAppliedCount',
      'ignoredGainAutoResumeCount',
      'focusPausedByPolicyAfterGain',
      'routingTerminalDisconnectAfterGain',
      'publicResumeAccepted',
      'publicResumeReason',
      'afterRejectedResumeState',
      'scenarioWallMs',
      'failureReason',
    ];

    final compactRouteDisconnectFocusGainBlocked = extractCompactScenario(
      routeDisconnectFocusGainBlockedMetrics,
      routeFocusBlockedCompactKeys,
    );

    const presentationClockCompactKeys = <String>[
      'pollerPollCount',
      'pollerValidCount',
      'pollerRegressionCount',
      'pollerFrameReadCount',
      'pollerUsReadCount',
      'pollerLastFrame',
      'pollerLastUs',
      'pollerMinFrame',
      'pollerMaxFrame',
      'pollerMinUs',
      'pollerMaxUs',
      'pollerThreadId',
      'pollerJoined',
      'pollerError',
      'presentationLagSampleCount',
      'presentationLagBoundedSampleCount',
      'presentationLagExcludedSampleCount',
      'lastPresentationLagFrames',
      'minPresentationLagFrames',
      'maxPresentationLagFrames',
      'presentationLagLowerBoundFrames',
      'presentationLagUpperBoundFrames',
      'lastPositionFramesAtPoll',
      'lastPositionUsAtPoll',
      'positionAtEosFrames',
      'positionAtEosUs',
      'currentPositionReadsFromWriterThread',
      'currentPositionReadsFromOtherThreads',
      'postTeardownCurrentPositionFrames',
      'postTeardownCurrentPositionUs',
      'nativeClockState',
      'nativeClockPositionUs',
      'nativeClockPositionFrame',
      'nativeClockDriftSampleCount',
      'presentationClockPositionUsAtCorrelation',
      'presentationClockPositionFramesAtCorrelation',
      'clockCorrelationOffsetUs',
      'clockCorrelationOffsetFrames',
      'clockCorrelationCommandsBefore',
      'clockCorrelationCommandsAfter',
      'driftSamplesPosted',
      'driftSamplesSkipped',
      'driftSamplesDropped',
      'driftCallbackCount',
      'driftSamplesRecorded',
      'driftSamplesStaleRejected',
      'driftSamplesOtherRejected',
      'driftLastRejectReason',
      'driftMaxQueueLatencyNs',
      'driftLastPostedGeneration',
      'driftLastExpectedPtsUs',
      'driftLastReportedPtsUs',
      'driftLastDeltaUs',
      'driftLastReportedFrame',
      'driftNativeSampleCount',
      'driftNativeSamplesRecorded',
      'driftNativeSamplesRejected',
      'staleProbeAttempted',
      'staleProbePostReturn',
      'staleProbeCallbackCount',
      'staleProbeStaleRejectedCount',
      'staleProbeReason',
      'staleProbeAccepted',
      'staleProbeNativeRecordedBefore',
      'staleProbeNativeRecordedAfter',
      'staleProbeNativeCountBefore',
      'staleProbeNativeCountAfter',
      'staleProbeCommandsBefore',
      'staleProbeCommandsAfter',
      'staleProbeStateBefore',
      'staleProbeStateAfter',
      'scenarioWallMs',
      'failureReason',
    ];

    final compactPresentationClock = extractCompactScenario(
      presentationClockQuerySurfaceMetrics,
      presentationClockCompactKeys,
    );

    const ringFrameSourceCompactKeys = <String>[
      'ringSampleRate',
      'ringChannelCount',
      'ringMaxFramesPerMix',
      'ringExpectedFrames',
      'ringSourceRingCapacityFrames',
      'ringOutputRingCapacityFrames',
      'ringFrameSourceUsed',
      'stateMachineSourceUsed',
      'sinkReadyBeforeTransportStart',
      'drainAllowedAfterTransportStart',
      'sinkExited',
      'sinkJoined',
      'ringClosed',
      'sinkFramesReadFromTransport',
      'sinkFramesWrittenToSink',
      'sinkEosDrainedObserved',
      'sinkChecksumHex',
      'ringFramesReadBySink',
      'ringTotalOutputFramesRead',
      'ringNativeOutputReadChecksumHex',
      'ringKotlinReferenceMixChecksumHex',
      'ringEosSetWithoutDrain',
      'ringEosDrainedObservedByRing',
      'ringTotalFramesPushedAtEos',
      'ringLaneRouteOk',
      'ringLaneSinkLifecycleOk',
      'ringLaneThreadOk',
      'ringLaneRingDrainOk',
      'ringLaneFrameAccountingOk',
      'ringLaneEosOk',
      'ringLaneChecksumOk',
      'ringLaneRingCloseOk',
      'ringLaneNativeOk',
      'ringLaneNoSeekPauseResumeOk',
      'ringLaneNoFeedbackOk',
      'ringLaneProofBoundaryOk',
      'scenarioWallMs',
      'failureReason',
    ];

    final compactRingFrameSource = extractCompactScenario(
      ringFrameSourceMetrics,
      ringFrameSourceCompactKeys,
    );

    const realDecoderRingFrameSourceCompactKeys = <String>[
      'realRingSourceMime',
      'realRingSourceTrackIndex',
      'realRingSampleRate',
      'realRingChannelCount',
      'realRingExpectedFrames',
      'realRingPadBudgetFrames',
      'realRingStage',
      'realRingFailureReason',
      'sinkFramesReadFromTransport',
      'sinkFramesWrittenToSink',
      'sinkEosDrainedObserved',
      'sinkChecksumHex',
      'sinkJoined',
      'realRingFramesReadBySink',
      'realRingTotalOutputFramesRead',
      'realRingNativeOutputReadChecksumHex',
      'realRingKotlinReferenceMixChecksumHex',
      'realRingKotlinTrack0ChecksumHex',
      'realRingKotlinTrack1ChecksumHex',
      'realRingEosSetWithoutDrain',
      'realRingEosDrainedObservedByRing',
      'realRingTotalFramesPushedAtEos',
      'realRingDestroyJoinOk',
      'realRingLaneNegativeProbeOk',
      'realRingLaneRouteOk',
      'realRingLaneFormatOk',
      'realRingLaneSinkLifecycleOk',
      'realRingLaneThreadOk',
      'realRingLaneRingDrainOk',
      'realRingLaneDrainLatencyOk',
      'realRingLaneFrameAccountingOk',
      'realRingLaneDecoderEosOk',
      'realRingLaneLockstepOk',
      'realRingLaneEosOk',
      'realRingLaneChecksumOk',
      'realRingLaneRingCloseOk',
      'realRingLaneNativeOk',
      'realRingLaneNoSeekPauseResumeOk',
      'realRingLaneNoFeedbackOk',
      'realRingLaneProofBoundaryOk',
      'scenarioWallMs',
      'failureReason',
    ];

    final compactRealDecoderRingFrameSource = extractCompactScenario(
      realDecoderRingFrameSourceMetrics,
      realDecoderRingFrameSourceCompactKeys,
    );

    const realRingPauseResumeCompactKeys = <String>[
      'realRingStage',
      'realRingFailureReason',
      'y19CoordinatorThreadId',
      'realRingOwnerThreadId',
      'realRingSinkThreadIdObserved',
      'realRingTransportCommandsIssued',
      'realRingQuiesceRequests',
      'realRingPauseRequests',
      'realRingHoldAssertRequests',
      'realRingResumeRequests',
      'realRingControlRequestsOnOwnerThread',
      'realRingControlOverlapRejects',
      'realRingControlWaitTimeouts',
      'y19SinkParkRequested',
      'y19SinkParked',
      'y19SinkParkedBeforeRingPause',
      'sinkParkCount',
      'sinkUnparkCount',
      'sinkSeekParkCount',
      'sinkFlushCount',
      'y19SinkUnparked',
      'y19SinkUnparkAfterRingResume',
      'realRingPauseAckOk',
      'realRingPauseExecutedOnOwnerThread',
      'realRingPauseCleanBoundaryOk',
      'realRingNativePauseProofOk',
      'realRingPauseCommandSeq',
      'realRingHoldAssertAckOk',
      'realRingNativeHoldFrozenProofOk',
      'realRingPauseHoldObservedMs',
      'realRingOwnerLoopIterationsWhilePaused',
      'realRingFeedStepsWhilePaused',
      'realRingEosPollsWhilePaused',
      'realRingDecodeStepsWhilePaused',
      'realRingMakeRoomCallbacksWhilePaused',
      'realRingPausedDrainRejectsSinkThread',
      'realRingPausedDrainRejectsOwnerThread',
      'realRingResumeAckOk',
      'realRingResumeExecutedOnOwnerThread',
      'realRingNativeResumeProofOk',
      'realRingResumeCommandSeq',
      'realRingDispatchCountAtResume',
      'realRingTotalFramesPushedAtResume',
      'realRingNativeLastPausedIntervalNs',
      'realRingNativeTotalPausedNs',
      'realRingStageAfterResume',
      'realRingPostResumeFramesReadBySink',
      'realRingFramesReadBySink',
      'realRingTotalOutputFramesRead',
      'realRingTotalFramesPushedAtEos',
      'realRingNativeOutputReadChecksumHex',
      'realRingKotlinReferenceMixChecksumHex',
      'realRingKotlinTrack0ChecksumHex',
      'realRingKotlinTrack1ChecksumHex',
      'realRingChecksumChainSelfOk',
      'realRingDestroyJoinOk',
      'realRingDestroyIdempotentOk',
      'y19SinkPhaseAtRingResume',
      'y19SinkRunning',
      'y19SinkFramesReadAtPark',
      'y19SinkFramesReadAtUnpark',
      'sinkPlayStateAfterUnpark',
      'sinkPositionAtPark',
      'sinkEpochClosedAtPark',
      'sinkEpochOpenedAtUnpark',
      'sinkEpochRawOriginAtUnpark',
      'y19LanePreUnparkReadFrozenOk',
      'y19LanePostUnparkReadMonotonicOk',
      'y19LanePauseCycleCountsOk',
      'y19LaneNoFeedbackOk',
      'y19LaneChecksumOk',
      'y19LaneNativeOk',
      'y19LaneBaseOk',
      'y19NonClaims',
      'scenarioWallMs',
      'failureReason',
    ];

    final compactRealRingPauseResume = extractCompactScenario(
      realRingPauseResumeMetrics,
      realRingPauseResumeCompactKeys,
    );

    print('--- METRICS ---');
    print('  [METRIC] sourceMime: ${lookupMetric('sourceMime')}');
    print('  [METRIC] sampleRate: ${lookupMetric('sampleRate')}');
    print('  [METRIC] channelCount: ${lookupMetric('channelCount')}');
    print(
      '  [METRIC] declaredFrameCount: ${lookupMetric('declaredFrameCount')}',
    );
    print('  [METRIC] maxDurationSec: ${lookupMetric('maxDurationSec')}');
    print('  [METRIC] maxFramesPerMix: ${lookupMetric('maxFramesPerMix')}');
    print('  [METRIC] gain: ${lookupMetric('gain')}');
    print('  [METRIC] deadlineMs: ${lookupMetric('deadlineMs')}');
    print('  [METRIC] pauseHoldMs: ${lookupMetric('pauseHoldMs')}');
    print(
      '  [METRIC] pauseHoldObservedMs: ${lookupMetric('pauseHoldObservedMs')}',
    );
    print('  [METRIC] stopAfterMs: ${lookupMetric('stopAfterMs')}');
    print(
      '  [METRIC] deadObjectInjectAfterFrames: ${lookupMetric('deadObjectInjectAfterFrames')}',
    );
    print('  [METRIC] preRollFrames: ${lookupMetric('preRollFrames')}');
    print(
      '  [METRIC] decoderAcceptedFrames: ${lookupMetric('decoderAcceptedFrames')}',
    );
    print(
      '  [METRIC] decoderChecksumHex: ${lookupMetric('decoderChecksumHex')}',
    );
    print('  [METRIC] decoderExitReason: ${lookupMetric('decoderExitReason')}');
    print(
      '  [METRIC] decoderMediaReleaseCount: ${lookupMetric('decoderMediaReleaseCount')}',
    );
    print(
      '  [METRIC] audioTrackReleaseCount: ${lookupMetric('audioTrackReleaseCount')}',
    );
    print(
      '  [METRIC] framesWrittenBeforeStop: ${lookupMetric('framesWrittenBeforeStop')}',
    );
    print('  [METRIC] stopAccepted: ${lookupMetric('stopAccepted')}');
    print('  [METRIC] stateAfterStop: ${lookupMetric('stateAfterStop')}');
    print('  [METRIC] stateAfterDispose: ${lookupMetric('stateAfterDispose')}');
    print(
      '  [METRIC] deadObjectRecoveryCount: ${lookupMetric('deadObjectRecoveryCount')}',
    );
    print(
      '  [METRIC] deadObjectRecoveryExecutedOnSinkThread: ${lookupMetric('deadObjectRecoveryExecutedOnSinkThread')}',
    );
    print(
      '  [METRIC] deadObjectRemainderAccountingOk: ${lookupMetric('deadObjectRemainderAccountingOk')}',
    );
    print(
      '  [METRIC] deadObjectBaseStepFrames: ${lookupMetric('deadObjectBaseStepFrames')}',
    );
    print(
      '  [METRIC] deadObjectContentHeadAtDeadObject: ${lookupMetric('deadObjectContentHeadAtDeadObject')}',
    );
    print(
      '  [METRIC] deadObjectWrittenAheadOfHeadFrames: ${lookupMetric('deadObjectWrittenAheadOfHeadFrames')}',
    );
    print(
      '  [METRIC] deadObjectPublicationLagFrames: ${lookupMetric('deadObjectPublicationLagFrames')}',
    );
    print(
      '  [METRIC] deadObjectBaseStepDecompositionOk: ${lookupMetric('deadObjectBaseStepDecompositionOk')}',
    );
    print(
      '  [METRIC] deadObjectClockProvenanceAtRecovery: ${lookupMetric('deadObjectClockProvenanceAtRecovery')}',
    );
    print('  [METRIC] seekTargetSec: ${lookupMetric('seekTargetSec')}');
    print(
      '  [METRIC] secondSeekTargetSec: ${lookupMetric('secondSeekTargetSec')}',
    );
    print('  [METRIC] target1Frame: ${lookupMetric('target1Frame')}');
    print('  [METRIC] target2Frame: ${lookupMetric('target2Frame')}');
    print('  [METRIC] hold1Frame: ${lookupMetric('hold1Frame')}');
    print('  [METRIC] hold2Frame: ${lookupMetric('hold2Frame')}');
    print('  [METRIC] sinkHold2Frame: ${lookupMetric('sinkHold2Frame')}');
    print('  [METRIC] thirdSeekCount: ${lookupMetric('thirdSeekCount')}');
    print('  [METRIC] finalSeekCount: ${lookupMetric('finalSeekCount')}');
    print(
      '  [METRIC] preSeekHoldWindows: ${lookupMetric('preSeekHoldWindows')}',
    );
    print('  [METRIC] maxSeekHoldMs: ${lookupMetric('maxSeekHoldMs')}');
    print('  [METRIC] seekTargetFrame: ${lookupMetric('seekTargetFrame')}');
    print('  [METRIC] preSeekHoldFrame: ${lookupMetric('preSeekHoldFrame')}');
    print('  [METRIC] seekCount: ${lookupMetric('seekCount')}');
    print('  [METRIC] seekAccepted: ${lookupMetric('seekAccepted')}');
    print('  [METRIC] sinkFlushCount: ${lookupMetric('sinkFlushCount')}');
    print('  [METRIC] decoderReanchorOk: ${lookupMetric('decoderReanchorOk')}');
    print(
      '  [METRIC] decoderStaleProbeRejected: ${lookupMetric('decoderStaleProbeRejected')}',
    );
    print(
      '  [METRIC] expectedTotalFrames: ${lookupMetric('expectedTotalFrames')}',
    );
    print(
      '  [METRIC] postSeekExpectedFrames: ${lookupMetric('postSeekExpectedFrames')}',
    );
    print('  [METRIC] duckGain: ${lookupMetric('duckGain')}');
    print('  [METRIC] focusEnabled: ${lookupMetric('focusEnabled')}');
    print(
      '  [METRIC] focusControllerRequested: ${lookupMetric('focusControllerRequested')}',
    );
    print(
      '  [METRIC] focusControllerGranted: ${lookupMetric('focusControllerGranted')}',
    );
    print(
      '  [METRIC] focusControllerNoisyRegistered: ${lookupMetric('focusControllerNoisyRegistered')}',
    );
    print(
      '  [METRIC] focusControllerReleased: ${lookupMetric('focusControllerReleased')}',
    );
    print(
      '  [METRIC] focusMonitorStarted: ${lookupMetric('focusMonitorStarted')}',
    );
    print(
      '  [METRIC] focusMonitorExited: ${lookupMetric('focusMonitorExited')}',
    );
    print(
      '  [METRIC] focusMonitorJoined: ${lookupMetric('focusMonitorJoined')}',
    );
    print(
      '  [METRIC] focusEventsDrained: ${lookupMetric('focusEventsDrained')}',
    );
    print(
      '  [METRIC] focusDuckAppliedCount: ${lookupMetric('focusDuckAppliedCount')}',
    );
    print(
      '  [METRIC] focusGainRestoreAppliedCount: ${lookupMetric('focusGainRestoreAppliedCount')}',
    );
    print(
      '  [METRIC] focusPauseTransientAppliedCount: ${lookupMetric('focusPauseTransientAppliedCount')}',
    );
    print(
      '  [METRIC] focusPauseNoisyAppliedCount: ${lookupMetric('focusPauseNoisyAppliedCount')}',
    );
    print(
      '  [METRIC] focusPausePermanentAppliedCount: ${lookupMetric('focusPausePermanentAppliedCount')}',
    );
    print(
      '  [METRIC] focusAutoResumeAppliedCount: ${lookupMetric('focusAutoResumeAppliedCount')}',
    );
    print(
      '  [METRIC] ignoredGainEventsDrained: ${lookupMetric('ignoredGainEventsDrained')}',
    );
    print(
      '  [METRIC] ignoredGainRestoreAppliedCount: ${lookupMetric('ignoredGainRestoreAppliedCount')}',
    );
    print(
      '  [METRIC] ignoredGainAutoResumeCount: ${lookupMetric('ignoredGainAutoResumeCount')}',
    );
    print('  [METRIC] sinkEffectiveGain: ${lookupMetric('sinkEffectiveGain')}');
    print('  [METRIC] routingEnabled: ${lookupMetric('routingEnabled')}');
    print(
      '  [METRIC] routingControllerAttached: ${lookupMetric('routingControllerAttached')}',
    );
    print(
      '  [METRIC] routingControllerReleased: ${lookupMetric('routingControllerReleased')}',
    );
    print(
      '  [METRIC] routingAttachCount: ${lookupMetric('routingAttachCount')}',
    );
    print(
      '  [METRIC] routingDetachCount: ${lookupMetric('routingDetachCount')}',
    );
    print(
      '  [METRIC] routingMonitorStarted: ${lookupMetric('routingMonitorStarted')}',
    );
    print(
      '  [METRIC] routingMonitorExited: ${lookupMetric('routingMonitorExited')}',
    );
    print(
      '  [METRIC] routingMonitorJoined: ${lookupMetric('routingMonitorJoined')}',
    );
    print(
      '  [METRIC] routeChangedAppliedCount: ${lookupMetric('routeChangedAppliedCount')}',
    );
    print(
      '  [METRIC] routeDisconnectAppliedCount: ${lookupMetric('routeDisconnectAppliedCount')}',
    );
    print(
      '  [METRIC] routingTerminalDisconnect: ${lookupMetric('routingTerminalDisconnect')}',
    );
    print(
      '  [METRIC] routingPausedByPolicy: ${lookupMetric('routingPausedByPolicy')}',
    );
    print('  [METRIC] routingLastAction: ${lookupMetric('routingLastAction')}');
    print('  [METRIC] routingLastReason: ${lookupMetric('routingLastReason')}');
    print(
      '  [METRIC] publicResumeAccepted: ${lookupMetric('publicResumeAccepted')}',
    );
    print(
      '  [METRIC] publicResumeReason: ${lookupMetric('publicResumeReason')}',
    );
    print(
      '  [METRIC] routingTerminalDisconnectAfterGain: ${lookupMetric('routingTerminalDisconnectAfterGain')}',
    );
    print('  [METRIC] nativeClockState: ${lookupMetric('nativeClockState')}');
    print(
      '  [METRIC] nativeClockPositionUs: ${lookupMetric('nativeClockPositionUs')}',
    );
    print(
      '  [METRIC] nativeClockPositionFrame: ${lookupMetric('nativeClockPositionFrame')}',
    );
    print(
      '  [METRIC] nativeClockDriftSampleCount: ${lookupMetric('nativeClockDriftSampleCount')}',
    );
    print(
      '  [METRIC] presentationClockPositionUsAtCorrelation: ${lookupMetric('presentationClockPositionUsAtCorrelation')}',
    );
    print(
      '  [METRIC] presentationClockPositionFramesAtCorrelation: ${lookupMetric('presentationClockPositionFramesAtCorrelation')}',
    );
    print(
      '  [METRIC] clockCorrelationOffsetUs: ${lookupMetric('clockCorrelationOffsetUs')}',
    );
    print(
      '  [METRIC] clockCorrelationOffsetFrames: ${lookupMetric('clockCorrelationOffsetFrames')}',
    );
    print(
      '  [METRIC] clockCorrelationCommandsBefore: ${lookupMetric('clockCorrelationCommandsBefore')}',
    );
    print(
      '  [METRIC] clockCorrelationCommandsAfter: ${lookupMetric('clockCorrelationCommandsAfter')}',
    );
    print(
      '  [METRIC] driftSamplesPosted: ${lookupMetric('driftSamplesPosted')}',
    );
    print(
      '  [METRIC] driftSamplesSkipped: ${lookupMetric('driftSamplesSkipped')}',
    );
    print(
      '  [METRIC] driftSamplesDropped: ${lookupMetric('driftSamplesDropped')}',
    );
    print(
      '  [METRIC] driftCallbackCount: ${lookupMetric('driftCallbackCount')}',
    );
    print(
      '  [METRIC] driftSamplesRecorded: ${lookupMetric('driftSamplesRecorded')}',
    );
    print(
      '  [METRIC] driftSamplesStaleRejected: ${lookupMetric('driftSamplesStaleRejected')}',
    );
    print(
      '  [METRIC] driftSamplesOtherRejected: ${lookupMetric('driftSamplesOtherRejected')}',
    );
    print(
      '  [METRIC] driftLastRejectReason: ${lookupMetric('driftLastRejectReason')}',
    );
    print(
      '  [METRIC] driftMaxQueueLatencyNs: ${lookupMetric('driftMaxQueueLatencyNs')}',
    );
    print(
      '  [METRIC] driftLastPostedGeneration: ${lookupMetric('driftLastPostedGeneration')}',
    );
    print(
      '  [METRIC] driftLastExpectedPtsUs: ${lookupMetric('driftLastExpectedPtsUs')}',
    );
    print(
      '  [METRIC] driftLastReportedPtsUs: ${lookupMetric('driftLastReportedPtsUs')}',
    );
    print('  [METRIC] driftLastDeltaUs: ${lookupMetric('driftLastDeltaUs')}');
    print(
      '  [METRIC] driftLastReportedFrame: ${lookupMetric('driftLastReportedFrame')}',
    );
    print(
      '  [METRIC] driftNativeSampleCount: ${lookupMetric('driftNativeSampleCount')}',
    );
    print(
      '  [METRIC] driftNativeSamplesRecorded: ${lookupMetric('driftNativeSamplesRecorded')}',
    );
    print(
      '  [METRIC] driftNativeSamplesRejected: ${lookupMetric('driftNativeSamplesRejected')}',
    );
    print(
      '  [METRIC] staleProbeAttempted: ${lookupMetric('staleProbeAttempted')}',
    );
    print('  [METRIC] staleProbeReason: ${lookupMetric('staleProbeReason')}');
    print(
      '  [METRIC] staleProbeAccepted: ${lookupMetric('staleProbeAccepted')}',
    );
    print('  [METRIC] failureReason: ${activeReport.failureReason}');
    print('  [METRIC] lastError: ${activeReport.lastError}');
    print('--- SCENARIO METRICS ---');
    print('  [SCENARIO] $playthroughScenarioKey: $compactPlaythrough');
    print('  [SCENARIO] $stopDisposeScenarioKey: $compactStopDispose');
    print('  [SCENARIO] $deadObjectScenarioKey: $compactDeadObject');
    print('  [SCENARIO] $forwardSeekScenarioKey: $compactForwardSeek');
    print('  [SCENARIO] $repeatedSeekScenarioKey: $compactRepeatedSeek');
    print('  [SCENARIO] $backwardSeekScenarioKey: $compactBackwardSeek');
    print(
      '  [SCENARIO] $focusDuckTransientNoisyScenarioKey: $compactFocusDuckTransientNoisy',
    );
    print(
      '  [SCENARIO] $focusPermanentLossScenarioKey: $compactFocusPermanentLoss',
    );
    print(
      '  [SCENARIO] $routeChangeObservationScenarioKey: $compactRouteChangeObservation',
    );
    print(
      '  [SCENARIO] $routeDisconnectTerminalPauseScenarioKey: $compactRouteDisconnectTerminalPause',
    );
    print(
      '  [SCENARIO] $routeDisconnectFocusGainBlockedScenarioKey: $compactRouteDisconnectFocusGainBlocked',
    );
    print(
      '  [SCENARIO] $presentationClockQuerySurfaceScenarioKey: $compactPresentationClock',
    );
    print('  [SCENARIO] $ringFrameSourceScenarioKey: $compactRingFrameSource');
    print(
      '  [SCENARIO] $realDecoderRingFrameSourceScenarioKey: $compactRealDecoderRingFrameSource',
    );
    print(
      '  [SCENARIO] $realRingPauseResumeScenarioKey: $compactRealRingPauseResume',
    );

    // 5. Verification evaluation.
    final pass =
        (topLevelError == null) &&
        activeReport.pass &&
        activeReport.isVerifiedPass &&
        activeReport.hasCanonicalProofBoundary &&
        activeReport.hasPassMarker;

    final compactScenarioMetrics = <String, dynamic>{
      playthroughScenarioKey: compactPlaythrough,
      stopDisposeScenarioKey: compactStopDispose,
      deadObjectScenarioKey: compactDeadObject,
      forwardSeekScenarioKey: compactForwardSeek,
      repeatedSeekScenarioKey: compactRepeatedSeek,
      backwardSeekScenarioKey: compactBackwardSeek,
      focusDuckTransientNoisyScenarioKey: compactFocusDuckTransientNoisy,
      focusPermanentLossScenarioKey: compactFocusPermanentLoss,
      routeChangeObservationScenarioKey: compactRouteChangeObservation,
      routeDisconnectTerminalPauseScenarioKey:
          compactRouteDisconnectTerminalPause,
      routeDisconnectFocusGainBlockedScenarioKey:
          compactRouteDisconnectFocusGainBlocked,
      presentationClockQuerySurfaceScenarioKey: compactPresentationClock,
      ringFrameSourceScenarioKey: compactRingFrameSource,
      realDecoderRingFrameSourceScenarioKey: compactRealDecoderRingFrameSource,
      realRingPauseResumeScenarioKey: compactRealRingPauseResume,
    };

    // 6. Print JSON marker with compact JSON payload.
    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealtimeAudioPlaybackProductionPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER-RING-PAUSE-RESUME',
      'subSlice': 'Y19',
      'target':
          VGRealtimeAudioPlaybackProductionSmokeReport.proofBoundaryConstant,
      'selectedFixture': selectedFixturePath,
      'pass': pass,
      'status': activeReport.status,
      'failureReason': activeReport.failureReason,
      'lanes': activeReport.lanes,
      'scenarioMetrics': compactScenarioMetrics,
      'scenarios': compactScenarioMetrics,
      'metrics': <String, dynamic>{
        'sourceMime': lookupMetric('sourceMime'),
        'sampleRate': lookupMetric('sampleRate'),
        'channelCount': lookupMetric('channelCount'),
        'declaredFrameCount': lookupMetric('declaredFrameCount'),
        'maxDurationSec': lookupMetric('maxDurationSec'),
        'maxFramesPerMix': lookupMetric('maxFramesPerMix'),
        'gain': lookupMetric('gain'),
        'deadlineMs': lookupMetric('deadlineMs'),
        'pauseHoldMs': lookupMetric('pauseHoldMs'),
        'pauseHoldObservedMs': lookupMetric('pauseHoldObservedMs'),
        'stopAfterMs': lookupMetric('stopAfterMs'),
        'deadObjectInjectAfterFrames': lookupMetric(
          'deadObjectInjectAfterFrames',
        ),
        'preRollFrames': lookupMetric('preRollFrames'),
        'decoderAcceptedFrames': lookupMetric('decoderAcceptedFrames'),
        'decoderChecksumHex': lookupMetric('decoderChecksumHex'),
        'decoderExitReason': lookupMetric('decoderExitReason'),
        'decoderMediaReleaseCount': lookupMetric('decoderMediaReleaseCount'),
        'audioTrackReleaseCount': lookupMetric('audioTrackReleaseCount'),
        'framesWrittenBeforeStop': lookupMetric('framesWrittenBeforeStop'),
        'stopAccepted': lookupMetric('stopAccepted'),
        'stateAfterStop': lookupMetric('stateAfterStop'),
        'stateAfterDispose': lookupMetric('stateAfterDispose'),
        'deadObjectRecoveryCount': lookupMetric('deadObjectRecoveryCount'),
        'deadObjectRecoveryExecutedOnSinkThread': lookupMetric(
          'deadObjectRecoveryExecutedOnSinkThread',
        ),
        'deadObjectRemainderAccountingOk': lookupMetric(
          'deadObjectRemainderAccountingOk',
        ),
        'deadObjectBaseStepFrames': lookupMetric('deadObjectBaseStepFrames'),
        'deadObjectContentHeadAtDeadObject': lookupMetric(
          'deadObjectContentHeadAtDeadObject',
        ),
        'deadObjectWrittenAheadOfHeadFrames': lookupMetric(
          'deadObjectWrittenAheadOfHeadFrames',
        ),
        'deadObjectPublicationLagFrames': lookupMetric(
          'deadObjectPublicationLagFrames',
        ),
        'deadObjectBaseStepDecompositionOk': lookupMetric(
          'deadObjectBaseStepDecompositionOk',
        ),
        'deadObjectClockProvenanceAtRecovery': lookupMetric(
          'deadObjectClockProvenanceAtRecovery',
        ),
        'seekTargetSec': lookupMetric('seekTargetSec'),
        'secondSeekTargetSec': lookupMetric('secondSeekTargetSec'),
        'target1Frame': lookupMetric('target1Frame'),
        'target2Frame': lookupMetric('target2Frame'),
        'hold1Frame': lookupMetric('hold1Frame'),
        'hold2Frame': lookupMetric('hold2Frame'),
        'sinkHold2Frame': lookupMetric('sinkHold2Frame'),
        'thirdSeekCount': lookupMetric('thirdSeekCount'),
        'finalSeekCount': lookupMetric('finalSeekCount'),
        'preSeekHoldWindows': lookupMetric('preSeekHoldWindows'),
        'maxSeekHoldMs': lookupMetric('maxSeekHoldMs'),
        'seekTargetFrame': lookupMetric('seekTargetFrame'),
        'preSeekHoldFrame': lookupMetric('preSeekHoldFrame'),
        'seekCount': lookupMetric('seekCount'),
        'seekAccepted': lookupMetric('seekAccepted'),
        'sinkFlushCount': lookupMetric('sinkFlushCount'),
        'decoderReanchorOk': lookupMetric('decoderReanchorOk'),
        'decoderStaleProbeRejected': lookupMetric('decoderStaleProbeRejected'),
        'expectedTotalFrames': lookupMetric('expectedTotalFrames'),
        'postSeekExpectedFrames': lookupMetric('postSeekExpectedFrames'),
        'duckGain': lookupMetric('duckGain'),
        'focusEnabled': lookupMetric('focusEnabled'),
        'focusControllerRequested': lookupMetric('focusControllerRequested'),
        'focusControllerGranted': lookupMetric('focusControllerGranted'),
        'focusControllerNoisyRegistered': lookupMetric(
          'focusControllerNoisyRegistered',
        ),
        'focusControllerReleased': lookupMetric('focusControllerReleased'),
        'focusMonitorStarted': lookupMetric('focusMonitorStarted'),
        'focusMonitorExited': lookupMetric('focusMonitorExited'),
        'focusMonitorJoined': lookupMetric('focusMonitorJoined'),
        'focusEventsDrained': lookupMetric('focusEventsDrained'),
        'focusDuckAppliedCount': lookupMetric('focusDuckAppliedCount'),
        'focusGainRestoreAppliedCount': lookupMetric(
          'focusGainRestoreAppliedCount',
        ),
        'focusPauseTransientAppliedCount': lookupMetric(
          'focusPauseTransientAppliedCount',
        ),
        'focusPauseNoisyAppliedCount': lookupMetric(
          'focusPauseNoisyAppliedCount',
        ),
        'focusPausePermanentAppliedCount': lookupMetric(
          'focusPausePermanentAppliedCount',
        ),
        'focusAutoResumeAppliedCount': lookupMetric(
          'focusAutoResumeAppliedCount',
        ),
        'ignoredGainEventsDrained': lookupMetric('ignoredGainEventsDrained'),
        'ignoredGainRestoreAppliedCount': lookupMetric(
          'ignoredGainRestoreAppliedCount',
        ),
        'ignoredGainAutoResumeCount': lookupMetric(
          'ignoredGainAutoResumeCount',
        ),
        'sinkEffectiveGain': lookupMetric('sinkEffectiveGain'),
        'routingEnabled': lookupMetric('routingEnabled'),
        'routingControllerAttached': lookupMetric('routingControllerAttached'),
        'routingControllerReleased': lookupMetric('routingControllerReleased'),
        'routingAttachCount': lookupMetric('routingAttachCount'),
        'routingDetachCount': lookupMetric('routingDetachCount'),
        'routingMonitorStarted': lookupMetric('routingMonitorStarted'),
        'routingMonitorExited': lookupMetric('routingMonitorExited'),
        'routingMonitorJoined': lookupMetric('routingMonitorJoined'),
        'routeChangedAppliedCount': lookupMetric('routeChangedAppliedCount'),
        'routeDisconnectAppliedCount': lookupMetric(
          'routeDisconnectAppliedCount',
        ),
        'routingTerminalDisconnect': lookupMetric('routingTerminalDisconnect'),
        'routingPausedByPolicy': lookupMetric('routingPausedByPolicy'),
        'routingLastAction': lookupMetric('routingLastAction'),
        'routingLastReason': lookupMetric('routingLastReason'),
        'publicResumeAccepted': lookupMetric('publicResumeAccepted'),
        'publicResumeReason': lookupMetric('publicResumeReason'),
        'routingTerminalDisconnectAfterGain': lookupMetric(
          'routingTerminalDisconnectAfterGain',
        ),
        'epochBaseFrame': lookupMetric('epochBaseFrame'),
        'framesWrittenAtEpochOpen': lookupMetric('framesWrittenAtEpochOpen'),
        'framesReadAtEpochOpen': lookupMetric('framesReadAtEpochOpen'),
        'presentationLagSampleCount': lookupMetric(
          'presentationLagSampleCount',
        ),
        'presentationLagBoundedSampleCount': lookupMetric(
          'presentationLagBoundedSampleCount',
        ),
        'presentationLagExcludedSampleCount': lookupMetric(
          'presentationLagExcludedSampleCount',
        ),
        'lastPresentationLagFrames': lookupMetric('lastPresentationLagFrames'),
        'minPresentationLagFrames': lookupMetric('minPresentationLagFrames'),
        'maxPresentationLagFrames': lookupMetric('maxPresentationLagFrames'),
        'presentationLagLowerBoundFrames': lookupMetric(
          'presentationLagLowerBoundFrames',
        ),
        'presentationLagUpperBoundFrames': lookupMetric(
          'presentationLagUpperBoundFrames',
        ),
        'lastPositionFramesAtPoll': lookupMetric('lastPositionFramesAtPoll'),
        'lastPositionUsAtPoll': lookupMetric('lastPositionUsAtPoll'),
        'positionAtEosFrames': lookupMetric('positionAtEosFrames'),
        'positionAtEosUs': lookupMetric('positionAtEosUs'),
        'currentPositionReadsFromWriterThread': lookupMetric(
          'currentPositionReadsFromWriterThread',
        ),
        'currentPositionReadsFromOtherThreads': lookupMetric(
          'currentPositionReadsFromOtherThreads',
        ),
        'pollerPollCount': lookupMetric('pollerPollCount'),
        'pollerValidCount': lookupMetric('pollerValidCount'),
        'pollerRegressionCount': lookupMetric('pollerRegressionCount'),
        'pollerFrameReadCount': lookupMetric('pollerFrameReadCount'),
        'pollerUsReadCount': lookupMetric('pollerUsReadCount'),
        'pollerLastFrame': lookupMetric('pollerLastFrame'),
        'pollerLastUs': lookupMetric('pollerLastUs'),
        'pollerMinFrame': lookupMetric('pollerMinFrame'),
        'pollerMaxFrame': lookupMetric('pollerMaxFrame'),
        'pollerMinUs': lookupMetric('pollerMinUs'),
        'pollerMaxUs': lookupMetric('pollerMaxUs'),
        'pollerThreadId': lookupMetric('pollerThreadId'),
        'pollerJoined': lookupMetric('pollerJoined'),
        'pollerError': lookupMetric('pollerError'),
        'pauseStartQueryFrames': lookupMetric('pauseStartQueryFrames'),
        'pauseStartQueryUs': lookupMetric('pauseStartQueryUs'),
        'pauseEndQueryFrames': lookupMetric('pauseEndQueryFrames'),
        'pauseEndQueryUs': lookupMetric('pauseEndQueryUs'),
        'afterRecoveryQueryFrames': lookupMetric('afterRecoveryQueryFrames'),
        'afterRecoveryQueryUs': lookupMetric('afterRecoveryQueryUs'),
        'afterSeekQueryFrames': lookupMetric('afterSeekQueryFrames'),
        'afterSeekQueryUs': lookupMetric('afterSeekQueryUs'),
        'afterSeek1QueryFrames': lookupMetric('afterSeek1QueryFrames'),
        'afterSeek1QueryUs': lookupMetric('afterSeek1QueryUs'),
        'afterSeek2QueryFrames': lookupMetric('afterSeek2QueryFrames'),
        'afterSeek2QueryUs': lookupMetric('afterSeek2QueryUs'),
        'afterSeek3QueryFrames': lookupMetric('afterSeek3QueryFrames'),
        'afterSeek3QueryUs': lookupMetric('afterSeek3QueryUs'),
        'postTeardownCurrentPositionFrames': lookupMetric(
          'postTeardownCurrentPositionFrames',
        ),
        'postTeardownCurrentPositionUs': lookupMetric(
          'postTeardownCurrentPositionUs',
        ),
        'nativeClockState': lookupMetric('nativeClockState'),
        'nativeClockPositionUs': lookupMetric('nativeClockPositionUs'),
        'nativeClockPositionFrame': lookupMetric('nativeClockPositionFrame'),
        'nativeClockDriftSampleCount': lookupMetric(
          'nativeClockDriftSampleCount',
        ),
        'presentationClockPositionUsAtCorrelation': lookupMetric(
          'presentationClockPositionUsAtCorrelation',
        ),
        'presentationClockPositionFramesAtCorrelation': lookupMetric(
          'presentationClockPositionFramesAtCorrelation',
        ),
        'clockCorrelationOffsetUs': lookupMetric('clockCorrelationOffsetUs'),
        'clockCorrelationOffsetFrames': lookupMetric(
          'clockCorrelationOffsetFrames',
        ),
        'clockCorrelationCommandsBefore': lookupMetric(
          'clockCorrelationCommandsBefore',
        ),
        'clockCorrelationCommandsAfter': lookupMetric(
          'clockCorrelationCommandsAfter',
        ),
        'driftSamplesPosted': lookupMetric('driftSamplesPosted'),
        'driftSamplesSkipped': lookupMetric('driftSamplesSkipped'),
        'driftSamplesDropped': lookupMetric('driftSamplesDropped'),
        'driftCallbackCount': lookupMetric('driftCallbackCount'),
        'driftSamplesRecorded': lookupMetric('driftSamplesRecorded'),
        'driftSamplesStaleRejected': lookupMetric('driftSamplesStaleRejected'),
        'driftSamplesOtherRejected': lookupMetric('driftSamplesOtherRejected'),
        'driftLastRejectReason': lookupMetric('driftLastRejectReason'),
        'driftMaxQueueLatencyNs': lookupMetric('driftMaxQueueLatencyNs'),
        'driftLastPostedGeneration': lookupMetric('driftLastPostedGeneration'),
        'driftLastExpectedPtsUs': lookupMetric('driftLastExpectedPtsUs'),
        'driftLastReportedPtsUs': lookupMetric('driftLastReportedPtsUs'),
        'driftLastDeltaUs': lookupMetric('driftLastDeltaUs'),
        'driftLastReportedFrame': lookupMetric('driftLastReportedFrame'),
        'driftNativeSampleCount': lookupMetric('driftNativeSampleCount'),
        'driftNativeSamplesRecorded': lookupMetric(
          'driftNativeSamplesRecorded',
        ),
        'driftNativeSamplesRejected': lookupMetric(
          'driftNativeSamplesRejected',
        ),
        'staleProbeAttempted': lookupMetric('staleProbeAttempted'),
        'staleProbePostReturn': lookupMetric('staleProbePostReturn'),
        'staleProbeCallbackCount': lookupMetric('staleProbeCallbackCount'),
        'staleProbeStaleRejectedCount': lookupMetric(
          'staleProbeStaleRejectedCount',
        ),
        'staleProbeReason': lookupMetric('staleProbeReason'),
        'staleProbeAccepted': lookupMetric('staleProbeAccepted'),
        'staleProbeNativeRecordedBefore': lookupMetric(
          'staleProbeNativeRecordedBefore',
        ),
        'staleProbeNativeRecordedAfter': lookupMetric(
          'staleProbeNativeRecordedAfter',
        ),
        'staleProbeNativeCountBefore': lookupMetric(
          'staleProbeNativeCountBefore',
        ),
        'staleProbeNativeCountAfter': lookupMetric(
          'staleProbeNativeCountAfter',
        ),
        'staleProbeCommandsBefore': lookupMetric('staleProbeCommandsBefore'),
        'staleProbeCommandsAfter': lookupMetric('staleProbeCommandsAfter'),
        'staleProbeStateBefore': lookupMetric('staleProbeStateBefore'),
        'staleProbeStateAfter': lookupMetric('staleProbeStateAfter'),
      },
      'error': topLevelError,
    };
    print(
      '${VGRealtimeAudioPlaybackProductionSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );

    // 7. Print PASS marker only when wrapper validation passes; otherwise print FAIL marker.
    if (pass) {
      print(VGRealtimeAudioPlaybackProductionSmokeReport.passMarkerConstant);
    } else {
      print(VGRealtimeAudioPlaybackProductionSmokeReport.failMarkerConstant);
    }

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (isVerifiedPass=true, allLanesPass=true)'
            : 'FAIL: lastError=${activeReport.lastError}, failureReason=${activeReport.failureReason}, error=$topLevelError';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 1000));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
