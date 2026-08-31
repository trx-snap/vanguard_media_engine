// vg_multi_source_audio_track_sink_smoke.dart
// vanguard_media_engine - P4-AUDIO-MULTI-SOURCE-AUDIOTRACK-SINK
// (P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice K): Android True-DAG Phase 4
// Multi-Source AudioTrack output sink write diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke` MethodChannel route.
// Diagnostic-only - validates the Kotlin-owned android.media.AudioTrack
// MODE_STREAM PCM16 output sink fed from the multi-source (real decoder +
// synthetic second track) closed-loop native audio graph pipeline output ring
// via AndroidMultiSourceAudioTrackPlaybackSinkDriver.
//
// Honest non-claims (Proof Boundary):
// kotlin_owned_android_audiotrack_multi_source_output_sink_write_diagnostic_proof_only_real_decoder_plus_synthetic_second_track_step_driven_closed_loop_native_audio_graph_pipeline_session_no_second_os_decoder_no_cpp_os_sink_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_frame_derived_virtual_ticks_only_system_nanotime_telemetry_only_audio_timestamp_conditional_telemetry_only_playback_head_consumption_assertion_only_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_clock_sync_no_av_sync_audiotrack_pause_flush_for_seek_epoch_only_no_transport_pause_resume_semantics_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_offload_no_low_latency_mode_no_aaudio_no_opensl_no_oboe_no_dead_object_recovery_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_truncation_beyond_budget_non_claim_two_routed_tracks_unit_gain_only_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_joint_tail_flush_diagnostic_only_no_jni_reverse_callbacks_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_source_node_pcm_ingest_topology_anchor_only_no_production_source_node_wiring_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim_no_in_band_dispose_cancellation_proof_detach_cancellation_source_audited_invariant_only

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGMultiSourceAudioTrackSinkSmokeReport.runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGMultiSourceAudioTrackSinkSmokeReport {
  const VGMultiSourceAudioTrackSinkSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.detachCancellationProven,
    required this.formatProbeOk,
    required this.audioTrackInitOk,
    required this.prerollOk,
    required this.playbackHeadMonotonicOk,
    required this.playbackHeadAdvancedOk,
    required this.playbackHeadBoundedOk,
    required this.sinkWriteAccountingOk,
    required this.seekEpochAccountingOk,
    required this.jointDispatchGateOk,
    required this.jointTailFlushOk,
    required this.twoTrackContributionOk,
    required this.referenceMixChecksumOk,
    required this.nativeDrainChecksumMatchesSinkOk,
    required this.trackFrameAxisLockstepOk,
    required this.mixedOutputFrameAccountingOk,
    required this.zeroNativeSteadyStateAllocationOk,
    required this.ownerThreadOk,
    required this.lifecycleOk,
    required this.canonical,
    required this.cancellationPollingLiveOk,
    required this.audioTimestampAvailable,
    required this.audioTimestampValidOk,
    required this.cancellationPollCount,
    required this.sampleRate,
    required this.channelCount,
    required this.commonBudgetFrames,
    required this.framesTruncatedBeyondBudget,
    required this.totalFramesExtracted,
    required this.playbackHeadFinal,
    required this.framesWrittenTotal,
    required this.framesReadFromRingTotal,
    required this.partialWriteCount,
    required this.zeroWriteCount,
    required this.getUnderrunCount,
    required this.bufferSizeInFrames,
    required this.bufferCapacityInFrames,
    required this.maxHeadLagFrames,
    required this.finalHeadLagFrames,
    required this.prerollFrames,
    required this.prerollEpochsSatisfied,
    required this.seekAcceptedFrame,
    required this.generatorReanchorCount,
    required this.track1NonZeroSampleCount,
    required this.totalFramesAcceptedTrack0,
    required this.totalFramesAcceptedTrack1,
    required this.totalOutputFramesDrained,
    required this.dispatchCount,
    required this.audioTimestampAttemptCount,
    required this.audioTimestampSuccessCount,
    required this.nativeOutputDrainChecksumHex,
    required this.kotlinReferenceMixChecksumHex,
    required this.kotlinSinkChecksumHex,
    required this.nativeLastStatus,
    required this.lanes,
    required this.metrics,
    required this.raw,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'kotlin_owned_android_audiotrack_multi_source_output_sink_write_diagnostic_proof_only_real_decoder_plus_synthetic_second_track_step_driven_closed_loop_native_audio_graph_pipeline_session_no_second_os_decoder_no_cpp_os_sink_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_frame_derived_virtual_ticks_only_system_nanotime_telemetry_only_audio_timestamp_conditional_telemetry_only_playback_head_consumption_assertion_only_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_clock_sync_no_av_sync_audiotrack_pause_flush_for_seek_epoch_only_no_transport_pause_resume_semantics_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_offload_no_low_latency_mode_no_aaudio_no_opensl_no_oboe_no_dead_object_recovery_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_truncation_beyond_budget_non_claim_two_routed_tracks_unit_gain_only_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_joint_tail_flush_diagnostic_only_no_jni_reverse_callbacks_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_source_node_pcm_ingest_topology_anchor_only_no_production_source_node_wiring_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim_no_in_band_dispose_cancellation_proof_detach_cancellation_source_audited_invariant_only';

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// Status string (e.g. 'pass', 'fail', or fail-closed reason token).
  final String status;

  /// Diagnostic marker string.
  final String marker;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// Failure reason token, if any.
  final String failureReason;

  /// Auxiliary execution details or trace breadcrumbs.
  final String details;

  /// Whether dispose cancellation was proven in-band. For this slice,
  /// detach cancellation is source-audited only and reported as false.
  final bool detachCancellationProven;

  // ---- Physically Asserted Required Lanes (19 lanes) -----------------------

  /// Whether initial audio format probe succeeded (PCM16, 1..2 channels).
  final bool formatProbeOk;

  /// Whether AudioTrack initialization succeeded with STATE_INITIALIZED.
  final bool audioTrackInitOk;

  /// Whether pre-roll frame requirements were satisfied before play().
  final bool prerollOk;

  /// Whether playback head advanced monotonically without regression.
  final bool playbackHeadMonotonicOk;

  /// Whether playback head advanced beyond baseline.
  final bool playbackHeadAdvancedOk;

  /// Whether playback head never exceeded total frames written.
  final bool playbackHeadBoundedOk;

  /// Whether frames read from ring equals frames written to AudioTrack.
  final bool sinkWriteAccountingOk;

  /// Whether seek epoch accounting and counter resets succeeded.
  final bool seekEpochAccountingOk;

  /// Whether joint dispatch gate deferred single-track and partial sub-windows correctly.
  final bool jointDispatchGateOk;

  /// Whether both pre-seek and final EOS tail flushes drained cleanly.
  final bool jointTailFlushOk;

  /// Whether mixed output checksum differs from both isolated track checksums.
  final bool twoTrackContributionOk;

  /// Whether native mixed output drain matches Kotlin reference mix checksum.
  final bool referenceMixChecksumOk;

  /// Whether native output drain checksum equals Kotlin sink write checksum.
  final bool nativeDrainChecksumMatchesSinkOk;

  /// Whether track 0, track 1, and Kotlin accepted frame counts are in exact lockstep.
  final bool trackFrameAxisLockstepOk;

  /// Whether total mixed output frames drained equals total accepted frames.
  final bool mixedOutputFrameAccountingOk;

  /// Whether ring and scheduler capacities remained constant across dispatches.
  final bool zeroNativeSteadyStateAllocationOk;

  /// Whether foreign thread operations were rejected with wrong_owner_thread.
  final bool ownerThreadOk;

  /// Whether session lifecycle creation, rejection, and destroy were idempotent.
  final bool lifecycleOk;

  /// Canonical pass indicator.
  final bool canonical;

  // ---- Conditional / Telemetry Lanes (3 lanes) ------------------------------

  /// Whether cancellation polling flag was actively polled during execution.
  final bool cancellationPollingLiveOk;

  /// Whether AudioTimestamp capability was available on the device track.
  final bool audioTimestampAvailable;

  /// Whether AudioTimestamp telemetry was valid (or track lacked capability).
  final bool audioTimestampValidOk;

  // ---- Metrics (31 metrics) ------------------------------------------------

  /// Total count of cancellation flag polls during execution.
  final int cancellationPollCount;

  /// Resolved sampling rate in Hz.
  final int sampleRate;

  /// Resolved channel count (1 or 2).
  final int channelCount;

  /// Common frame budget L calculated as round(durationSec * sampleRate).
  final int commonBudgetFrames;

  /// Extracted frames truncated beyond the common budget L (explicit non-claim).
  final int framesTruncatedBeyondBudget;

  /// Total frames extracted from MediaExtractor.
  final int totalFramesExtracted;

  /// Final playback head frame position in the last epoch.
  final int playbackHeadFinal;

  /// Total frames written to the AudioTrack.
  final int framesWrittenTotal;

  /// Total frames read from the native output ring into the sink buffer.
  final int framesReadFromRingTotal;

  /// Count of partial AudioTrack.write occurrences.
  final int partialWriteCount;

  /// Count of zero-byte AudioTrack.write occurrences.
  final int zeroWriteCount;

  /// Total underrun count reported by AudioTrack.getUnderrunCount.
  final int getUnderrunCount;

  /// AudioTrack buffer size in frames.
  final int bufferSizeInFrames;

  /// AudioTrack buffer capacity in frames.
  final int bufferCapacityInFrames;

  /// Maximum observed playback head lag in frames.
  final int maxHeadLagFrames;

  /// Final playback head lag in frames at completion (must be 0 for pass).
  final int finalHeadLagFrames;

  /// Total pre-roll frames required.
  final int prerollFrames;

  /// Count of pre-roll epochs satisfied before play().
  final int prerollEpochsSatisfied;

  /// Native accepted frame boundary for seek re-anchoring.
  final int seekAcceptedFrame;

  /// Count of synthetic generator re-anchors across seek boundaries.
  final int generatorReanchorCount;

  /// Non-zero synthetic PCM sample count generated for track 1.
  final int track1NonZeroSampleCount;

  /// Total frames accepted on Track 0 (real decoder).
  final int totalFramesAcceptedTrack0;

  /// Total frames accepted on Track 1 (synthetic generator).
  final int totalFramesAcceptedTrack1;

  /// Total frames drained from the mixed output ring.
  final int totalOutputFramesDrained;

  /// Total dispatch cycles executed during the run.
  final int dispatchCount;

  /// Count of AudioTimestamp query attempts.
  final int audioTimestampAttemptCount;

  /// Count of successful AudioTimestamp queries.
  final int audioTimestampSuccessCount;

  /// 64-bit hexadecimal checksum computed on the native mixed output drain side.
  final String nativeOutputDrainChecksumHex;

  /// 64-bit hexadecimal checksum computed on the Kotlin reference mix side.
  final String kotlinReferenceMixChecksumHex;

  /// 64-bit hexadecimal checksum computed on the Kotlin sink write side.
  final String kotlinSinkChecksumHex;

  /// Last native status string snapshot.
  final String nativeLastStatus;

  // ---- Raw & Nested Maps ----------------------------------------------------

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Map of raw string outputs emitted by native smoke execution.
  final Map<String, String> raw;

  /// Last error string from native execution, if any.
  final String lastError;

  // ---- Getters --------------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether Kotlin reference mix checksum, native output drain checksum, and
  /// Kotlin sink write checksum match, are non-empty, and both
  /// [referenceMixChecksumOk] and [nativeDrainChecksumMatchesSinkOk] hold.
  bool get checksumsMatch =>
      nativeOutputDrainChecksumHex.isNotEmpty &&
      kotlinReferenceMixChecksumHex.isNotEmpty &&
      kotlinSinkChecksumHex.isNotEmpty &&
      nativeOutputDrainChecksumHex == kotlinReferenceMixChecksumHex &&
      nativeOutputDrainChecksumHex == kotlinSinkChecksumHex &&
      referenceMixChecksumOk &&
      nativeDrainChecksumMatchesSinkOk;

  /// Whether all native diagnostic lanes passed according to the P4 multi-source
  /// AudioTrack output sink verification contract.
  ///
  /// Note: [audioTimestampAvailable] is conditional telemetry and is NOT
  /// required to be true for overall pass. [detachCancellationProven] is
  /// source-audited and reported as false.
  bool get allNativeLanesPass =>
      pass &&
      hasCanonicalProofBoundary &&
      status.toLowerCase() == 'pass' &&
      marker == passMarkerConstant &&
      formatProbeOk &&
      audioTrackInitOk &&
      prerollOk &&
      playbackHeadMonotonicOk &&
      playbackHeadAdvancedOk &&
      playbackHeadBoundedOk &&
      sinkWriteAccountingOk &&
      seekEpochAccountingOk &&
      jointDispatchGateOk &&
      jointTailFlushOk &&
      twoTrackContributionOk &&
      referenceMixChecksumOk &&
      nativeDrainChecksumMatchesSinkOk &&
      trackFrameAxisLockstepOk &&
      mixedOutputFrameAccountingOk &&
      zeroNativeSteadyStateAllocationOk &&
      ownerThreadOk &&
      lifecycleOk &&
      canonical &&
      cancellationPollingLiveOk &&
      audioTimestampValidOk &&
      cancellationPollCount > 0 &&
      sampleRate > 0 &&
      channelCount > 0 &&
      commonBudgetFrames > 0 &&
      totalFramesExtracted > 0 &&
      playbackHeadFinal > 0 &&
      framesWrittenTotal > 0 &&
      framesReadFromRingTotal > 0 &&
      framesWrittenTotal == framesReadFromRingTotal &&
      framesReadFromRingTotal == totalOutputFramesDrained &&
      prerollFrames > 0 &&
      prerollEpochsSatisfied > 0 &&
      seekAcceptedFrame >= 0 &&
      generatorReanchorCount > 0 &&
      track1NonZeroSampleCount > 0 &&
      totalFramesAcceptedTrack0 > 0 &&
      totalFramesAcceptedTrack1 > 0 &&
      totalFramesAcceptedTrack0 == totalFramesAcceptedTrack1 &&
      totalOutputFramesDrained > 0 &&
      totalOutputFramesDrained == totalFramesAcceptedTrack0 &&
      dispatchCount > 0 &&
      finalHeadLagFrames == 0 &&
      checksumsMatch &&
      (lastError.isEmpty || lastError == 'none' || lastError == 'null');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGMultiSourceAudioTrackSinkSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGMultiSourceAudioTrackSinkSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        detachCancellationProven: false,
        formatProbeOk: false,
        audioTrackInitOk: false,
        prerollOk: false,
        playbackHeadMonotonicOk: false,
        playbackHeadAdvancedOk: false,
        playbackHeadBoundedOk: false,
        sinkWriteAccountingOk: false,
        seekEpochAccountingOk: false,
        jointDispatchGateOk: false,
        jointTailFlushOk: false,
        twoTrackContributionOk: false,
        referenceMixChecksumOk: false,
        nativeDrainChecksumMatchesSinkOk: false,
        trackFrameAxisLockstepOk: false,
        mixedOutputFrameAccountingOk: false,
        zeroNativeSteadyStateAllocationOk: false,
        ownerThreadOk: false,
        lifecycleOk: false,
        canonical: false,
        cancellationPollingLiveOk: false,
        audioTimestampAvailable: false,
        audioTimestampValidOk: false,
        cancellationPollCount: 0,
        sampleRate: 0,
        channelCount: 0,
        commonBudgetFrames: 0,
        framesTruncatedBeyondBudget: 0,
        totalFramesExtracted: 0,
        playbackHeadFinal: 0,
        framesWrittenTotal: 0,
        framesReadFromRingTotal: 0,
        partialWriteCount: 0,
        zeroWriteCount: 0,
        getUnderrunCount: -1,
        bufferSizeInFrames: 0,
        bufferCapacityInFrames: 0,
        maxHeadLagFrames: 0,
        finalHeadLagFrames: -1,
        prerollFrames: 0,
        prerollEpochsSatisfied: 0,
        seekAcceptedFrame: -1,
        generatorReanchorCount: 0,
        track1NonZeroSampleCount: 0,
        totalFramesAcceptedTrack0: 0,
        totalFramesAcceptedTrack1: 0,
        totalOutputFramesDrained: 0,
        dispatchCount: 0,
        audioTimestampAttemptCount: 0,
        audioTimestampSuccessCount: 0,
        nativeOutputDrainChecksumHex: '',
        kotlinReferenceMixChecksumHex: '',
        kotlinSinkChecksumHex: '',
        nativeLastStatus: '',
        lanes: <String, Object?>{
          'formatProbeOk': false,
          'audioTrackInitOk': false,
          'prerollOk': false,
          'playbackHeadMonotonicOk': false,
          'playbackHeadAdvancedOk': false,
          'playbackHeadBoundedOk': false,
          'sinkWriteAccountingOk': false,
          'seekEpochAccountingOk': false,
          'jointDispatchGateOk': false,
          'jointTailFlushOk': false,
          'twoTrackContributionOk': false,
          'referenceMixChecksumOk': false,
          'nativeDrainChecksumMatchesSinkOk': false,
          'trackFrameAxisLockstepOk': false,
          'mixedOutputFrameAccountingOk': false,
          'zeroNativeSteadyStateAllocationOk': false,
          'ownerThreadOk': false,
          'lifecycleOk': false,
          'canonical': false,
          'cancellationPollingLiveOk': false,
          'audioTimestampAvailable': false,
          'audioTimestampValidOk': false,
        },
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        raw: <String, String>{'reason': 'native_result_not_a_map'},
        lastError: 'native_result_not_a_map',
      );
    }

    final rawMapInput = raw['raw'];
    final parsedRaw = <String, String>{};
    if (rawMapInput is Map) {
      for (final entry in rawMapInput.entries) {
        final k = entry.key?.toString();
        final v = entry.value?.toString();
        if (k != null && v != null) {
          parsedRaw[k] = v;
        }
      }
    } else if (rawMapInput is String && rawMapInput.isNotEmpty) {
      for (final part in rawMapInput.split(';')) {
        final eq = part.indexOf('=');
        if (eq > 0) {
          final k = part.substring(0, eq).trim();
          final v = part.substring(eq + 1).trim();
          if (k.isNotEmpty) {
            parsedRaw[k] = v;
          }
        }
      }
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

    bool parseBool(String key, [bool defaultValue = false]) {
      final v =
          parsedLanes[key] ?? raw[key] ?? parsedMetrics[key] ?? parsedRaw[key];
      if (v is bool) {
        return v;
      }
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
      return defaultValue;
    }

    int parseInt(String key, [int defaultValue = 0]) {
      final v =
          parsedMetrics[key] ?? raw[key] ?? parsedLanes[key] ?? parsedRaw[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim()) ?? defaultValue;
      return defaultValue;
    }

    String parseString(String key, [String defaultValue = '']) {
      final v =
          raw[key] ?? parsedMetrics[key] ?? parsedLanes[key] ?? parsedRaw[key];
      if (v != null) return v.toString();
      return defaultValue;
    }

    final pass = parseBool(
      'pass',
      parsedRaw['status']?.toLowerCase() == 'pass',
    );
    final status = parseString('status', pass ? 'pass' : 'fail');
    final marker = parseString(
      'marker',
      pass ? passMarkerConstant : failMarkerConstant,
    );
    final proofBoundary = parseString('proofBoundary');
    final failureReason = parseString(
      'failureReason',
      parsedRaw['reason'] ?? '',
    );
    final details = parseString('details');
    final detachCancellationProven = parseBool(
      'detachCancellationProven',
      false,
    );

    final formatProbeOk = parseBool('formatProbeOk');
    final audioTrackInitOk = parseBool('audioTrackInitOk');
    final prerollOk = parseBool('prerollOk');
    final playbackHeadMonotonicOk = parseBool('playbackHeadMonotonicOk');
    final playbackHeadAdvancedOk = parseBool('playbackHeadAdvancedOk');
    final playbackHeadBoundedOk = parseBool('playbackHeadBoundedOk');
    final sinkWriteAccountingOk = parseBool('sinkWriteAccountingOk');
    final seekEpochAccountingOk = parseBool('seekEpochAccountingOk');
    final jointDispatchGateOk = parseBool('jointDispatchGateOk');
    final jointTailFlushOk = parseBool('jointTailFlushOk');
    final twoTrackContributionOk = parseBool('twoTrackContributionOk');
    final referenceMixChecksumOk = parseBool('referenceMixChecksumOk');
    final nativeDrainChecksumMatchesSinkOk = parseBool(
      'nativeDrainChecksumMatchesSinkOk',
    );
    final trackFrameAxisLockstepOk = parseBool('trackFrameAxisLockstepOk');
    final mixedOutputFrameAccountingOk = parseBool(
      'mixedOutputFrameAccountingOk',
    );
    final zeroNativeSteadyStateAllocationOk = parseBool(
      'zeroNativeSteadyStateAllocationOk',
    );
    final ownerThreadOk = parseBool('ownerThreadOk');
    final lifecycleOk = parseBool('lifecycleOk');
    final canonical = parseBool('canonical', pass);

    final cancellationPollingLiveOk = parseBool('cancellationPollingLiveOk');
    final audioTimestampAvailable = parseBool('audioTimestampAvailable');
    final audioTimestampValidOk = parseBool('audioTimestampValidOk');

    final cancellationPollCount = parseInt('cancellationPollCount');
    final sampleRate = parseInt('sampleRate');
    final channelCount = parseInt('channelCount');
    final commonBudgetFrames = parseInt('commonBudgetFrames');
    final framesTruncatedBeyondBudget = parseInt('framesTruncatedBeyondBudget');
    final totalFramesExtracted = parseInt('totalFramesExtracted');
    final playbackHeadFinal = parseInt('playbackHeadFinal');
    final framesWrittenTotal = parseInt('framesWrittenTotal');
    final framesReadFromRingTotal = parseInt('framesReadFromRingTotal');
    final partialWriteCount = parseInt('partialWriteCount');
    final zeroWriteCount = parseInt('zeroWriteCount');
    final getUnderrunCount = parseInt('getUnderrunCount', -1);
    final bufferSizeInFrames = parseInt('bufferSizeInFrames');
    final bufferCapacityInFrames = parseInt('bufferCapacityInFrames');
    final maxHeadLagFrames = parseInt('maxHeadLagFrames');
    final finalHeadLagFrames = parseInt('finalHeadLagFrames', -1);
    final prerollFrames = parseInt('prerollFrames');
    final prerollEpochsSatisfied = parseInt('prerollEpochsSatisfied');
    final seekAcceptedFrame = parseInt('seekAcceptedFrame', -1);
    final generatorReanchorCount = parseInt('generatorReanchorCount');
    final track1NonZeroSampleCount = parseInt('track1NonZeroSampleCount');
    final totalFramesAcceptedTrack0 = parseInt('totalFramesAcceptedTrack0');
    final totalFramesAcceptedTrack1 = parseInt('totalFramesAcceptedTrack1');
    final totalOutputFramesDrained = parseInt('totalOutputFramesDrained');
    final dispatchCount = parseInt('dispatchCount');
    final audioTimestampAttemptCount = parseInt('audioTimestampAttemptCount');
    final audioTimestampSuccessCount = parseInt('audioTimestampSuccessCount');
    final nativeOutputDrainChecksumHex = parseString(
      'nativeOutputDrainChecksumHex',
    );
    final kotlinReferenceMixChecksumHex = parseString(
      'kotlinReferenceMixChecksumHex',
    );
    final kotlinSinkChecksumHex = parseString('kotlinSinkChecksumHex');
    final nativeLastStatus = parseString('nativeLastStatus');

    final lastError = parseString(
      'lastError',
      failureReason.isNotEmpty ? failureReason : (pass ? '' : status),
    );

    final finalLanes = <String, Object?>{
      'formatProbeOk': formatProbeOk,
      'audioTrackInitOk': audioTrackInitOk,
      'prerollOk': prerollOk,
      'playbackHeadMonotonicOk': playbackHeadMonotonicOk,
      'playbackHeadAdvancedOk': playbackHeadAdvancedOk,
      'playbackHeadBoundedOk': playbackHeadBoundedOk,
      'sinkWriteAccountingOk': sinkWriteAccountingOk,
      'seekEpochAccountingOk': seekEpochAccountingOk,
      'jointDispatchGateOk': jointDispatchGateOk,
      'jointTailFlushOk': jointTailFlushOk,
      'twoTrackContributionOk': twoTrackContributionOk,
      'referenceMixChecksumOk': referenceMixChecksumOk,
      'nativeDrainChecksumMatchesSinkOk': nativeDrainChecksumMatchesSinkOk,
      'trackFrameAxisLockstepOk': trackFrameAxisLockstepOk,
      'mixedOutputFrameAccountingOk': mixedOutputFrameAccountingOk,
      'zeroNativeSteadyStateAllocationOk': zeroNativeSteadyStateAllocationOk,
      'ownerThreadOk': ownerThreadOk,
      'lifecycleOk': lifecycleOk,
      'canonical': canonical,
      'cancellationPollingLiveOk': cancellationPollingLiveOk,
      'audioTimestampAvailable': audioTimestampAvailable,
      'audioTimestampValidOk': audioTimestampValidOk,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{
      'cancellationPollCount': cancellationPollCount,
      'sampleRate': sampleRate,
      'channelCount': channelCount,
      'commonBudgetFrames': commonBudgetFrames,
      'framesTruncatedBeyondBudget': framesTruncatedBeyondBudget,
      'totalFramesExtracted': totalFramesExtracted,
      'playbackHeadFinal': playbackHeadFinal,
      'framesWrittenTotal': framesWrittenTotal,
      'framesReadFromRingTotal': framesReadFromRingTotal,
      'partialWriteCount': partialWriteCount,
      'zeroWriteCount': zeroWriteCount,
      'getUnderrunCount': getUnderrunCount,
      'bufferSizeInFrames': bufferSizeInFrames,
      'bufferCapacityInFrames': bufferCapacityInFrames,
      'maxHeadLagFrames': maxHeadLagFrames,
      'finalHeadLagFrames': finalHeadLagFrames,
      'prerollFrames': prerollFrames,
      'prerollEpochsSatisfied': prerollEpochsSatisfied,
      'seekAcceptedFrame': seekAcceptedFrame,
      'generatorReanchorCount': generatorReanchorCount,
      'track1NonZeroSampleCount': track1NonZeroSampleCount,
      'totalFramesAcceptedTrack0': totalFramesAcceptedTrack0,
      'totalFramesAcceptedTrack1': totalFramesAcceptedTrack1,
      'totalOutputFramesDrained': totalOutputFramesDrained,
      'dispatchCount': dispatchCount,
      'audioTimestampAttemptCount': audioTimestampAttemptCount,
      'audioTimestampSuccessCount': audioTimestampSuccessCount,
      'nativeOutputDrainChecksumHex': nativeOutputDrainChecksumHex,
      'kotlinReferenceMixChecksumHex': kotlinReferenceMixChecksumHex,
      'kotlinSinkChecksumHex': kotlinSinkChecksumHex,
      'nativeLastStatus': nativeLastStatus,
      ...parsedMetrics,
    };

    return VGMultiSourceAudioTrackSinkSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      details: details,
      detachCancellationProven: detachCancellationProven,
      formatProbeOk: formatProbeOk,
      audioTrackInitOk: audioTrackInitOk,
      prerollOk: prerollOk,
      playbackHeadMonotonicOk: playbackHeadMonotonicOk,
      playbackHeadAdvancedOk: playbackHeadAdvancedOk,
      playbackHeadBoundedOk: playbackHeadBoundedOk,
      sinkWriteAccountingOk: sinkWriteAccountingOk,
      seekEpochAccountingOk: seekEpochAccountingOk,
      jointDispatchGateOk: jointDispatchGateOk,
      jointTailFlushOk: jointTailFlushOk,
      twoTrackContributionOk: twoTrackContributionOk,
      referenceMixChecksumOk: referenceMixChecksumOk,
      nativeDrainChecksumMatchesSinkOk: nativeDrainChecksumMatchesSinkOk,
      trackFrameAxisLockstepOk: trackFrameAxisLockstepOk,
      mixedOutputFrameAccountingOk: mixedOutputFrameAccountingOk,
      zeroNativeSteadyStateAllocationOk: zeroNativeSteadyStateAllocationOk,
      ownerThreadOk: ownerThreadOk,
      lifecycleOk: lifecycleOk,
      canonical: canonical,
      cancellationPollingLiveOk: cancellationPollingLiveOk,
      audioTimestampAvailable: audioTimestampAvailable,
      audioTimestampValidOk: audioTimestampValidOk,
      cancellationPollCount: cancellationPollCount,
      sampleRate: sampleRate,
      channelCount: channelCount,
      commonBudgetFrames: commonBudgetFrames,
      framesTruncatedBeyondBudget: framesTruncatedBeyondBudget,
      totalFramesExtracted: totalFramesExtracted,
      playbackHeadFinal: playbackHeadFinal,
      framesWrittenTotal: framesWrittenTotal,
      framesReadFromRingTotal: framesReadFromRingTotal,
      partialWriteCount: partialWriteCount,
      zeroWriteCount: zeroWriteCount,
      getUnderrunCount: getUnderrunCount,
      bufferSizeInFrames: bufferSizeInFrames,
      bufferCapacityInFrames: bufferCapacityInFrames,
      maxHeadLagFrames: maxHeadLagFrames,
      finalHeadLagFrames: finalHeadLagFrames,
      prerollFrames: prerollFrames,
      prerollEpochsSatisfied: prerollEpochsSatisfied,
      seekAcceptedFrame: seekAcceptedFrame,
      generatorReanchorCount: generatorReanchorCount,
      track1NonZeroSampleCount: track1NonZeroSampleCount,
      totalFramesAcceptedTrack0: totalFramesAcceptedTrack0,
      totalFramesAcceptedTrack1: totalFramesAcceptedTrack1,
      totalOutputFramesDrained: totalOutputFramesDrained,
      dispatchCount: dispatchCount,
      audioTimestampAttemptCount: audioTimestampAttemptCount,
      audioTimestampSuccessCount: audioTimestampSuccessCount,
      nativeOutputDrainChecksumHex: nativeOutputDrainChecksumHex,
      kotlinReferenceMixChecksumHex: kotlinReferenceMixChecksumHex,
      kotlinSinkChecksumHex: kotlinSinkChecksumHex,
      nativeLastStatus: nativeLastStatus,
      lanes: Map<String, Object?>.unmodifiable(finalLanes),
      metrics: Map<String, Object?>.unmodifiable(finalMetrics),
      raw: Map<String, String>.unmodifiable(parsedRaw),
      lastError: lastError,
    );
  }

  /// Serializes the report back to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'status': status,
      'marker': marker,
      'proofBoundary': proofBoundary,
      'failureReason': failureReason,
      'details': details,
      'detachCancellationProven': detachCancellationProven,
      'lanes': Map<String, Object?>.from(lanes),
      'metrics': Map<String, Object?>.from(metrics),
      'raw': Map<String, String>.from(raw),
      'lastError': lastError,
    };
  }

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static VGMultiSourceAudioTrackSinkSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      'formatProbeOk': false,
      'audioTrackInitOk': false,
      'prerollOk': false,
      'playbackHeadMonotonicOk': false,
      'playbackHeadAdvancedOk': false,
      'playbackHeadBoundedOk': false,
      'sinkWriteAccountingOk': false,
      'seekEpochAccountingOk': false,
      'jointDispatchGateOk': false,
      'jointTailFlushOk': false,
      'twoTrackContributionOk': false,
      'referenceMixChecksumOk': false,
      'nativeDrainChecksumMatchesSinkOk': false,
      'trackFrameAxisLockstepOk': false,
      'mixedOutputFrameAccountingOk': false,
      'zeroNativeSteadyStateAllocationOk': false,
      'ownerThreadOk': false,
      'lifecycleOk': false,
      'canonical': false,
      'cancellationPollingLiveOk': false,
      'audioTimestampAvailable': false,
      'audioTimestampValidOk': false,
    };
    final metrics = <String, Object?>{
      'cancellationPollCount': 0,
      'sampleRate': 0,
      'channelCount': 0,
      'commonBudgetFrames': 0,
      'framesTruncatedBeyondBudget': 0,
      'totalFramesExtracted': 0,
      'playbackHeadFinal': 0,
      'framesWrittenTotal': 0,
      'framesReadFromRingTotal': 0,
      'partialWriteCount': 0,
      'zeroWriteCount': 0,
      'getUnderrunCount': -1,
      'bufferSizeInFrames': 0,
      'bufferCapacityInFrames': 0,
      'maxHeadLagFrames': 0,
      'finalHeadLagFrames': -1,
      'prerollFrames': 0,
      'prerollEpochsSatisfied': 0,
      'seekAcceptedFrame': -1,
      'generatorReanchorCount': 0,
      'track1NonZeroSampleCount': 0,
      'totalFramesAcceptedTrack0': 0,
      'totalFramesAcceptedTrack1': 0,
      'totalOutputFramesDrained': 0,
      'dispatchCount': 0,
      'audioTimestampAttemptCount': 0,
      'audioTimestampSuccessCount': 0,
      'nativeOutputDrainChecksumHex': '',
      'kotlinReferenceMixChecksumHex': '',
      'kotlinSinkChecksumHex': '',
      'nativeLastStatus': '',
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGMultiSourceAudioTrackSinkSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      detachCancellationProven: false,
      formatProbeOk: false,
      audioTrackInitOk: false,
      prerollOk: false,
      playbackHeadMonotonicOk: false,
      playbackHeadAdvancedOk: false,
      playbackHeadBoundedOk: false,
      sinkWriteAccountingOk: false,
      seekEpochAccountingOk: false,
      jointDispatchGateOk: false,
      jointTailFlushOk: false,
      twoTrackContributionOk: false,
      referenceMixChecksumOk: false,
      nativeDrainChecksumMatchesSinkOk: false,
      trackFrameAxisLockstepOk: false,
      mixedOutputFrameAccountingOk: false,
      zeroNativeSteadyStateAllocationOk: false,
      ownerThreadOk: false,
      lifecycleOk: false,
      canonical: false,
      cancellationPollingLiveOk: false,
      audioTimestampAvailable: false,
      audioTimestampValidOk: false,
      cancellationPollCount: 0,
      sampleRate: 0,
      channelCount: 0,
      commonBudgetFrames: 0,
      framesTruncatedBeyondBudget: 0,
      totalFramesExtracted: 0,
      playbackHeadFinal: 0,
      framesWrittenTotal: 0,
      framesReadFromRingTotal: 0,
      partialWriteCount: 0,
      zeroWriteCount: 0,
      getUnderrunCount: -1,
      bufferSizeInFrames: 0,
      bufferCapacityInFrames: 0,
      maxHeadLagFrames: 0,
      finalHeadLagFrames: -1,
      prerollFrames: 0,
      prerollEpochsSatisfied: 0,
      seekAcceptedFrame: -1,
      generatorReanchorCount: 0,
      track1NonZeroSampleCount: 0,
      totalFramesAcceptedTrack0: 0,
      totalFramesAcceptedTrack1: 0,
      totalOutputFramesDrained: 0,
      dispatchCount: 0,
      audioTimestampAttemptCount: 0,
      audioTimestampSuccessCount: 0,
      nativeOutputDrainChecksumHex: '',
      kotlinReferenceMixChecksumHex: '',
      kotlinSinkChecksumHex: '',
      nativeLastStatus: '',
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      raw: Map<String, String>.unmodifiable(<String, String>{
        'status': 'FAIL',
        'reason': reason,
      }),
      lastError: lastError,
    );
  }

  /// Invokes the Android True-DAG Phase 4 multi-source AudioTrack output sink
  /// write diagnostic proof smoke harness.
  ///
  /// [sourcePath] path to the source audio/video media file (required).
  /// [durationSec] duration in seconds to process (default 1.0, max 2.0).
  /// [seekTargetSec] seek target position in seconds (default 0.35).
  /// [volume] playback volume 0.0..1.0 (default 0.0).
  /// [sourceRingCapacityFrames] capacity of source ring in frames (default 8192).
  /// [outputRingCapacityFrames] capacity of output ring in frames (default 4096).
  /// [maxFramesPerMix] max frames per mix dispatch cycle (default 256).
  /// [timeout] optionally bounds the invocation; deadlineMs is passed to Kotlin.
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGMultiSourceAudioTrackSinkSmokeReport>
  runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke({
    required String sourcePath,
    double durationSec = 1.0,
    double seekTargetSec = 0.35,
    double volume = 0.0,
    int sourceRingCapacityFrames = 8192,
    int outputRingCapacityFrames = 4096,
    int maxFramesPerMix = 256,
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final args = <String, Object?>{
      'sourcePath': sourcePath,
      'durationSec': durationSec,
      'seekTargetSec': seekTargetSec,
      'volume': volume,
      'sourceRingCapacityFrames': sourceRingCapacityFrames,
      'outputRingCapacityFrames': outputRingCapacityFrames,
      'maxFramesPerMix': maxFramesPerMix,
      'deadlineMs': timeout != null ? timeout.inMilliseconds : 30000,
    };
    try {
      final future = ch.invokeMethod<Object?>(methodName, args);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGMultiSourceAudioTrackSinkSmokeReport.fromMap(raw);
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
    return other is VGMultiSourceAudioTrackSinkSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.detachCancellationProven == detachCancellationProven &&
        other.formatProbeOk == formatProbeOk &&
        other.audioTrackInitOk == audioTrackInitOk &&
        other.prerollOk == prerollOk &&
        other.playbackHeadMonotonicOk == playbackHeadMonotonicOk &&
        other.playbackHeadAdvancedOk == playbackHeadAdvancedOk &&
        other.playbackHeadBoundedOk == playbackHeadBoundedOk &&
        other.sinkWriteAccountingOk == sinkWriteAccountingOk &&
        other.seekEpochAccountingOk == seekEpochAccountingOk &&
        other.jointDispatchGateOk == jointDispatchGateOk &&
        other.jointTailFlushOk == jointTailFlushOk &&
        other.twoTrackContributionOk == twoTrackContributionOk &&
        other.referenceMixChecksumOk == referenceMixChecksumOk &&
        other.nativeDrainChecksumMatchesSinkOk ==
            nativeDrainChecksumMatchesSinkOk &&
        other.trackFrameAxisLockstepOk == trackFrameAxisLockstepOk &&
        other.mixedOutputFrameAccountingOk == mixedOutputFrameAccountingOk &&
        other.zeroNativeSteadyStateAllocationOk ==
            zeroNativeSteadyStateAllocationOk &&
        other.ownerThreadOk == ownerThreadOk &&
        other.lifecycleOk == lifecycleOk &&
        other.canonical == canonical &&
        other.cancellationPollingLiveOk == cancellationPollingLiveOk &&
        other.audioTimestampAvailable == audioTimestampAvailable &&
        other.audioTimestampValidOk == audioTimestampValidOk &&
        other.cancellationPollCount == cancellationPollCount &&
        other.sampleRate == sampleRate &&
        other.channelCount == channelCount &&
        other.commonBudgetFrames == commonBudgetFrames &&
        other.framesTruncatedBeyondBudget == framesTruncatedBeyondBudget &&
        other.totalFramesExtracted == totalFramesExtracted &&
        other.playbackHeadFinal == playbackHeadFinal &&
        other.framesWrittenTotal == framesWrittenTotal &&
        other.framesReadFromRingTotal == framesReadFromRingTotal &&
        other.partialWriteCount == partialWriteCount &&
        other.zeroWriteCount == zeroWriteCount &&
        other.getUnderrunCount == getUnderrunCount &&
        other.bufferSizeInFrames == bufferSizeInFrames &&
        other.bufferCapacityInFrames == bufferCapacityInFrames &&
        other.maxHeadLagFrames == maxHeadLagFrames &&
        other.finalHeadLagFrames == finalHeadLagFrames &&
        other.prerollFrames == prerollFrames &&
        other.prerollEpochsSatisfied == prerollEpochsSatisfied &&
        other.seekAcceptedFrame == seekAcceptedFrame &&
        other.generatorReanchorCount == generatorReanchorCount &&
        other.track1NonZeroSampleCount == track1NonZeroSampleCount &&
        other.totalFramesAcceptedTrack0 == totalFramesAcceptedTrack0 &&
        other.totalFramesAcceptedTrack1 == totalFramesAcceptedTrack1 &&
        other.totalOutputFramesDrained == totalOutputFramesDrained &&
        other.dispatchCount == dispatchCount &&
        other.audioTimestampAttemptCount == audioTimestampAttemptCount &&
        other.audioTimestampSuccessCount == audioTimestampSuccessCount &&
        other.nativeOutputDrainChecksumHex == nativeOutputDrainChecksumHex &&
        other.kotlinReferenceMixChecksumHex == kotlinReferenceMixChecksumHex &&
        other.kotlinSinkChecksumHex == kotlinSinkChecksumHex &&
        other.nativeLastStatus == nativeLastStatus &&
        mapEquals(other.lanes, lanes) &&
        mapEquals(other.metrics, metrics) &&
        mapEquals(other.raw, raw) &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hashAll([
    pass,
    status,
    marker,
    proofBoundary,
    failureReason,
    details,
    detachCancellationProven,
    formatProbeOk,
    audioTrackInitOk,
    prerollOk,
    playbackHeadMonotonicOk,
    playbackHeadAdvancedOk,
    playbackHeadBoundedOk,
    sinkWriteAccountingOk,
    seekEpochAccountingOk,
    jointDispatchGateOk,
    jointTailFlushOk,
    twoTrackContributionOk,
    referenceMixChecksumOk,
    nativeDrainChecksumMatchesSinkOk,
    trackFrameAxisLockstepOk,
    mixedOutputFrameAccountingOk,
    zeroNativeSteadyStateAllocationOk,
    ownerThreadOk,
    lifecycleOk,
    canonical,
    cancellationPollingLiveOk,
    audioTimestampAvailable,
    audioTimestampValidOk,
    cancellationPollCount,
    sampleRate,
    channelCount,
    commonBudgetFrames,
    framesTruncatedBeyondBudget,
    totalFramesExtracted,
    playbackHeadFinal,
    framesWrittenTotal,
    framesReadFromRingTotal,
    partialWriteCount,
    zeroWriteCount,
    getUnderrunCount,
    bufferSizeInFrames,
    bufferCapacityInFrames,
    maxHeadLagFrames,
    finalHeadLagFrames,
    prerollFrames,
    prerollEpochsSatisfied,
    seekAcceptedFrame,
    generatorReanchorCount,
    track1NonZeroSampleCount,
    totalFramesAcceptedTrack0,
    totalFramesAcceptedTrack1,
    totalOutputFramesDrained,
    dispatchCount,
    audioTimestampAttemptCount,
    audioTimestampSuccessCount,
    nativeOutputDrainChecksumHex,
    kotlinReferenceMixChecksumHex,
    kotlinSinkChecksumHex,
    nativeLastStatus,
    _stableMapHash(lanes),
    _stableMapHash(metrics),
    _stableMapHash(raw),
    lastError,
  ]);

  static int _stableMapHash(Map<dynamic, dynamic> map) {
    final sortedKeys = map.keys.map((k) => k.toString()).toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGMultiSourceAudioTrackSinkSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'failureReason: $failureReason, '
      'details: $details, '
      'detachCancellationProven: $detachCancellationProven, '
      'formatProbeOk: $formatProbeOk, '
      'audioTrackInitOk: $audioTrackInitOk, '
      'prerollOk: $prerollOk, '
      'playbackHeadMonotonicOk: $playbackHeadMonotonicOk, '
      'playbackHeadAdvancedOk: $playbackHeadAdvancedOk, '
      'playbackHeadBoundedOk: $playbackHeadBoundedOk, '
      'sinkWriteAccountingOk: $sinkWriteAccountingOk, '
      'seekEpochAccountingOk: $seekEpochAccountingOk, '
      'jointDispatchGateOk: $jointDispatchGateOk, '
      'jointTailFlushOk: $jointTailFlushOk, '
      'twoTrackContributionOk: $twoTrackContributionOk, '
      'referenceMixChecksumOk: $referenceMixChecksumOk, '
      'nativeDrainChecksumMatchesSinkOk: $nativeDrainChecksumMatchesSinkOk, '
      'trackFrameAxisLockstepOk: $trackFrameAxisLockstepOk, '
      'mixedOutputFrameAccountingOk: $mixedOutputFrameAccountingOk, '
      'zeroNativeSteadyStateAllocationOk: $zeroNativeSteadyStateAllocationOk, '
      'ownerThreadOk: $ownerThreadOk, '
      'lifecycleOk: $lifecycleOk, '
      'canonical: $canonical, '
      'cancellationPollingLiveOk: $cancellationPollingLiveOk, '
      'audioTimestampAvailable: $audioTimestampAvailable, '
      'audioTimestampValidOk: $audioTimestampValidOk, '
      'cancellationPollCount: $cancellationPollCount, '
      'sampleRate: $sampleRate, '
      'channelCount: $channelCount, '
      'commonBudgetFrames: $commonBudgetFrames, '
      'framesTruncatedBeyondBudget: $framesTruncatedBeyondBudget, '
      'totalFramesExtracted: $totalFramesExtracted, '
      'playbackHeadFinal: $playbackHeadFinal, '
      'framesWrittenTotal: $framesWrittenTotal, '
      'framesReadFromRingTotal: $framesReadFromRingTotal, '
      'partialWriteCount: $partialWriteCount, '
      'zeroWriteCount: $zeroWriteCount, '
      'getUnderrunCount: $getUnderrunCount, '
      'bufferSizeInFrames: $bufferSizeInFrames, '
      'bufferCapacityInFrames: $bufferCapacityInFrames, '
      'maxHeadLagFrames: $maxHeadLagFrames, '
      'finalHeadLagFrames: $finalHeadLagFrames, '
      'prerollFrames: $prerollFrames, '
      'prerollEpochsSatisfied: $prerollEpochsSatisfied, '
      'seekAcceptedFrame: $seekAcceptedFrame, '
      'generatorReanchorCount: $generatorReanchorCount, '
      'track1NonZeroSampleCount: $track1NonZeroSampleCount, '
      'totalFramesAcceptedTrack0: $totalFramesAcceptedTrack0, '
      'totalFramesAcceptedTrack1: $totalFramesAcceptedTrack1, '
      'totalOutputFramesDrained: $totalOutputFramesDrained, '
      'dispatchCount: $dispatchCount, '
      'audioTimestampAttemptCount: $audioTimestampAttemptCount, '
      'audioTimestampSuccessCount: $audioTimestampSuccessCount, '
      'nativeOutputDrainChecksumHex: $nativeOutputDrainChecksumHex, '
      'kotlinReferenceMixChecksumHex: $kotlinReferenceMixChecksumHex, '
      'kotlinSinkChecksumHex: $kotlinSinkChecksumHex, '
      'nativeLastStatus: $nativeLastStatus, '
      'lanes: $lanes, '
      'metrics: $metrics, '
      'raw: $raw, '
      'lastError: $lastError)';
}
