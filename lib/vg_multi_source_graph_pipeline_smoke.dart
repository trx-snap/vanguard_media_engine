// vg_multi_source_graph_pipeline_smoke.dart
// vanguard_media_engine - P4-AUDIO-MULTI-SOURCE-GRAPH-PIPELINE: Android True-DAG Phase 4
// two-source closed-loop native audio graph pipeline diagnostic smoke foundation
// (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4MultiSourceGraphPipelineSmoke` MethodChannel route.
// Diagnostic-only - validates the two-source closed-loop native audio graph
// pipeline JNI session driven by one real MediaExtractor/MediaCodec decoder track
// plus one Kotlin-synthesized PCM track in lockstep on the shared accepted-frame axis:
// [Real Decoder (Track 0) + Synthetic (Track 1)] ->
// AudioDecoderRingWriter -> source AudioSpscAudioRingBuffers ->
// RingBufferAudioSampleProviders -> GraphAudioScheduler -> AudioMixBusNode ->
// ClockedAudioTransportCoordinator -> output AudioSpscAudioRingBuffer -> consumer drain.
// Two routed tracks at unit gain with caller-derived clock ticks.
//
// Honest non-claims (Proof Boundary):
// kotlin_owned_real_decoder_plus_synthetic_second_track_step_driven_multi_source_closed_loop_native_audio_graph_pipeline_session_proof_only_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_diagnostic_graph_topology_only_two_routed_tracks_unit_gain_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_joint_tail_flush_diagnostic_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGMultiSourceGraphPipelineSmokeReport.runAndroidDagPhase4MultiSourceGraphPipelineSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGMultiSourceGraphPipelineSmokeReport {
  const VGMultiSourceGraphPipelineSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.topologyRoutedSourcesOk,
    required this.track0IngestOk,
    required this.track1SyntheticIngestOk,
    required this.trackFrameAxisLockstepOk,
    required this.jointDispatchGateOk,
    required this.referenceMixChecksumOk,
    required this.mixedOutputFrameAccountingOk,
    required this.twoTrackContributionOk,
    required this.seekOk,
    required this.jointTailFlushOk,
    required this.noProviderUnderrunOk,
    required this.noZeroFillOk,
    required this.noForwardSkipOk,
    required this.noRewindRejectOk,
    required this.noSilenceOk,
    required this.noRingPushShortfallOk,
    required this.zeroNativeSteadyStateAllocationOk,
    required this.ownerThreadOk,
    required this.lifecycleOk,
    required this.canonical,
    required this.sampleRate,
    required this.channelCount,
    required this.pcmEncoding,
    required this.commonBudgetFrames,
    required this.framesTruncatedBeyondBudget,
    required this.totalFramesExtracted,
    required this.totalFramesAcceptedTrack0,
    required this.totalFramesAcceptedTrack1,
    required this.totalOutputFramesDrained,
    required this.postSeekFramesAccepted,
    required this.postSeekFramesDrained,
    required this.seekAcceptedFrame,
    required this.track1NonZeroSampleCount,
    required this.mixedChecksumDiffersFromTrack0,
    required this.mixedChecksumDiffersFromTrack1,
    required this.decoderBenignFormatChangeCount,
    required this.providerUnderrunEventsTrack0,
    required this.providerUnderrunEventsTrack1,
    required this.providerFramesZeroFilledTrack0,
    required this.providerFramesZeroFilledTrack1,
    required this.providerForwardSkipFramesTrack0,
    required this.providerForwardSkipFramesTrack1,
    required this.providerRewindRejectsTrack0,
    required this.providerRewindRejectsTrack1,
    required this.coordinatorSilenceCount,
    required this.nativeAcceptedChecksumHexTrack0,
    required this.nativeAcceptedChecksumHexTrack1,
    required this.nativeOutputDrainChecksumHex,
    required this.kotlinAcceptedChecksumHexTrack0,
    required this.kotlinAcceptedChecksumHexTrack1,
    required this.kotlinReferenceMixChecksumHex,
    required this.maxFramesPerMix,
    required this.sourceAvailableReadFramesTrack0,
    required this.sourceAvailableReadFramesTrack1,
    required this.outputAvailableReadFrames,
    required this.dispatchCount,
    required this.nextDispatchFrame,
    required this.nativeLastStatus,
    required this.lanes,
    required this.metrics,
    required this.raw,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidDagPhase4MultiSourceGraphPipelineSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_MULTI_SOURCE_GRAPH_PIPELINE_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_MULTI_SOURCE_GRAPH_PIPELINE_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'kotlin_owned_real_decoder_plus_synthetic_second_track_step_driven_multi_source_closed_loop_native_audio_graph_pipeline_session_proof_only_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_diagnostic_graph_topology_only_two_routed_tracks_unit_gain_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_joint_tail_flush_diagnostic_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim';

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

  // ---- Lanes (21 lanes) ---------------------------------------------------

  /// Whether initial audio format probe succeeded (PCM16, 1..2 channels).
  final bool formatProbeOk;

  /// Whether native topology confirmed exactly 2 routed source nodes.
  final bool topologyRoutedSourcesOk;

  /// Whether track 0 real decoder ingest checksum identity holds.
  final bool track0IngestOk;

  /// Whether track 1 synthetic ingest checksum identity holds with non-zero samples.
  final bool track1SyntheticIngestOk;

  /// Whether track 0, track 1, and Kotlin accepted frame counts are in exact lockstep.
  final bool trackFrameAxisLockstepOk;

  /// Whether joint dispatch gate deferred single-track and partial sub-windows correctly.
  final bool jointDispatchGateOk;

  /// Whether native mixed output drain matches Kotlin reference mix checksum.
  final bool referenceMixChecksumOk;

  /// Whether total mixed output frames drained equals total accepted frames.
  final bool mixedOutputFrameAccountingOk;

  /// Whether mixed output checksum differs from both isolated track checksums.
  final bool twoTrackContributionOk;

  /// Whether joint accepted-frame-axis seek re-anchored both tracks with zero discards.
  final bool seekOk;

  /// Whether joint EOS tail flush drained both source rings and output to zero.
  final bool jointTailFlushOk;

  /// Whether no provider underruns occurred on either track.
  final bool noProviderUnderrunOk;

  /// Whether no provider zero-fills occurred on either track.
  final bool noZeroFillOk;

  /// Whether no forward frame skips occurred on either track.
  final bool noForwardSkipOk;

  /// Whether no rewind frame rejects occurred on either track.
  final bool noRewindRejectOk;

  /// Whether no coordinator silence windows occurred.
  final bool noSilenceOk;

  /// Whether no ring push shortfall or terminal errors occurred.
  final bool noRingPushShortfallOk;

  /// Whether ring and scheduler capacities remained constant across dispatches.
  final bool zeroNativeSteadyStateAllocationOk;

  /// Whether foreign thread operations were rejected with wrong_owner_thread.
  final bool ownerThreadOk;

  /// Whether session lifecycle creation, start, and destroy were idempotent.
  final bool lifecycleOk;

  /// Canonical pass indicator.
  final bool canonical;

  // ---- Metrics (38 metrics) -----------------------------------------------

  /// Resolved sampling rate in Hz.
  final int sampleRate;

  /// Resolved channel count (1 or 2).
  final int channelCount;

  /// Resolved PCM encoding (AudioFormat.ENCODING_PCM_16BIT = 2).
  final int pcmEncoding;

  /// Common frame budget L calculated as round(durationSec * sampleRate).
  final int commonBudgetFrames;

  /// Extracted frames truncated beyond the common budget L (explicit non-claim).
  final int framesTruncatedBeyondBudget;

  /// Total frames extracted from MediaExtractor.
  final int totalFramesExtracted;

  /// Total frames accepted on Track 0 (real decoder).
  final int totalFramesAcceptedTrack0;

  /// Total frames accepted on Track 1 (synthetic generator).
  final int totalFramesAcceptedTrack1;

  /// Total frames drained from the mixed output ring.
  final int totalOutputFramesDrained;

  /// Frames accepted after the joint seek boundary.
  final int postSeekFramesAccepted;

  /// Frames drained after the joint seek boundary.
  final int postSeekFramesDrained;

  /// Accepted frame index at which joint seek re-anchoring occurred.
  final int seekAcceptedFrame;

  /// Non-zero synthetic PCM sample count generated for track 1.
  final int track1NonZeroSampleCount;

  /// Whether mixed output checksum differs from track 0 accepted checksum.
  final bool mixedChecksumDiffersFromTrack0;

  /// Whether mixed output checksum differs from track 1 accepted checksum.
  final bool mixedChecksumDiffersFromTrack1;

  /// Count of benign repeated format change events observed.
  final int decoderBenignFormatChangeCount;

  /// Provider underrun events count on track 0 (must be 0).
  final int providerUnderrunEventsTrack0;

  /// Provider underrun events count on track 1 (must be 0).
  final int providerUnderrunEventsTrack1;

  /// Provider frames zero-filled count on track 0 (must be 0).
  final int providerFramesZeroFilledTrack0;

  /// Provider frames zero-filled count on track 1 (must be 0).
  final int providerFramesZeroFilledTrack1;

  /// Provider forward skip frames count on track 0 (must be 0).
  final int providerForwardSkipFramesTrack0;

  /// Provider forward skip frames count on track 1 (must be 0).
  final int providerForwardSkipFramesTrack1;

  /// Provider rewind frame rejects count on track 0 (must be 0).
  final int providerRewindRejectsTrack0;

  /// Provider rewind frame rejects count on track 1 (must be 0).
  final int providerRewindRejectsTrack1;

  /// Coordinator silence windows count (must be 0).
  final int coordinatorSilenceCount;

  /// 64-bit hexadecimal checksum computed on native track 0 accepted side.
  final String nativeAcceptedChecksumHexTrack0;

  /// 64-bit hexadecimal checksum computed on native track 1 accepted side.
  final String nativeAcceptedChecksumHexTrack1;

  /// 64-bit hexadecimal checksum computed on native mixed output drain side.
  final String nativeOutputDrainChecksumHex;

  /// 64-bit hexadecimal checksum computed on Kotlin track 0 accepted side.
  final String kotlinAcceptedChecksumHexTrack0;

  /// 64-bit hexadecimal checksum computed on Kotlin track 1 accepted side.
  final String kotlinAcceptedChecksumHexTrack1;

  /// 64-bit hexadecimal checksum computed on Kotlin reference mix side.
  final String kotlinReferenceMixChecksumHex;

  /// Maximum frames rendered per mix dispatch cycle.
  final int maxFramesPerMix;

  /// Source ring 0 available read frames at last snapshot.
  final int sourceAvailableReadFramesTrack0;

  /// Source ring 1 available read frames at last snapshot.
  final int sourceAvailableReadFramesTrack1;

  /// Output ring available read frames at last snapshot.
  final int outputAvailableReadFrames;

  /// Total dispatch cycles executed during the run.
  final int dispatchCount;

  /// Next dispatch frame index.
  final int nextDispatchFrame;

  /// Last native status string snapshot.
  final String nativeLastStatus;

  // ---- Raw & Nested Maps --------------------------------------------------

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Map of raw string outputs emitted by native smoke execution.
  final Map<String, String> raw;

  /// Last error string from native execution, if any.
  final String lastError;

  // ---- Getters ------------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether Kotlin accepted and native accepted checksums match for both tracks,
  /// Kotlin reference mix checksum matches native output drain checksum, all are non-empty,
  /// and [track0IngestOk], [track1SyntheticIngestOk], and [referenceMixChecksumOk] hold.
  bool get checksumsMatch =>
      kotlinAcceptedChecksumHexTrack0.isNotEmpty &&
      nativeAcceptedChecksumHexTrack0.isNotEmpty &&
      kotlinAcceptedChecksumHexTrack0 == nativeAcceptedChecksumHexTrack0 &&
      kotlinAcceptedChecksumHexTrack1.isNotEmpty &&
      nativeAcceptedChecksumHexTrack1.isNotEmpty &&
      kotlinAcceptedChecksumHexTrack1 == nativeAcceptedChecksumHexTrack1 &&
      kotlinReferenceMixChecksumHex.isNotEmpty &&
      nativeOutputDrainChecksumHex.isNotEmpty &&
      kotlinReferenceMixChecksumHex == nativeOutputDrainChecksumHex &&
      track0IngestOk &&
      track1SyntheticIngestOk &&
      referenceMixChecksumOk;

  /// Whether all native diagnostic lanes passed according to the P4 multi-source
  /// graph pipeline verification contract.
  bool get allNativeLanesPass =>
      pass &&
      hasCanonicalProofBoundary &&
      status.toLowerCase() == 'pass' &&
      marker == passMarkerConstant &&
      formatProbeOk &&
      topologyRoutedSourcesOk &&
      track0IngestOk &&
      track1SyntheticIngestOk &&
      trackFrameAxisLockstepOk &&
      jointDispatchGateOk &&
      referenceMixChecksumOk &&
      mixedOutputFrameAccountingOk &&
      twoTrackContributionOk &&
      seekOk &&
      jointTailFlushOk &&
      noProviderUnderrunOk &&
      noZeroFillOk &&
      noForwardSkipOk &&
      noRewindRejectOk &&
      noSilenceOk &&
      noRingPushShortfallOk &&
      zeroNativeSteadyStateAllocationOk &&
      ownerThreadOk &&
      lifecycleOk &&
      canonical &&
      sampleRate > 0 &&
      channelCount > 0 &&
      commonBudgetFrames > 0 &&
      totalFramesAcceptedTrack0 > 0 &&
      totalFramesAcceptedTrack1 > 0 &&
      totalFramesAcceptedTrack0 == totalFramesAcceptedTrack1 &&
      totalOutputFramesDrained > 0 &&
      totalOutputFramesDrained == totalFramesAcceptedTrack0 &&
      postSeekFramesAccepted > 0 &&
      postSeekFramesDrained > 0 &&
      track1NonZeroSampleCount > 0 &&
      mixedChecksumDiffersFromTrack0 &&
      mixedChecksumDiffersFromTrack1 &&
      dispatchCount > 0 &&
      maxFramesPerMix > 0 &&
      providerUnderrunEventsTrack0 == 0 &&
      providerUnderrunEventsTrack1 == 0 &&
      providerFramesZeroFilledTrack0 == 0 &&
      providerFramesZeroFilledTrack1 == 0 &&
      providerForwardSkipFramesTrack0 == 0 &&
      providerForwardSkipFramesTrack1 == 0 &&
      providerRewindRejectsTrack0 == 0 &&
      providerRewindRejectsTrack1 == 0 &&
      coordinatorSilenceCount == 0 &&
      checksumsMatch &&
      (lastError.isEmpty || lastError == 'none' || lastError == 'null');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGMultiSourceGraphPipelineSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGMultiSourceGraphPipelineSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        formatProbeOk: false,
        topologyRoutedSourcesOk: false,
        track0IngestOk: false,
        track1SyntheticIngestOk: false,
        trackFrameAxisLockstepOk: false,
        jointDispatchGateOk: false,
        referenceMixChecksumOk: false,
        mixedOutputFrameAccountingOk: false,
        twoTrackContributionOk: false,
        seekOk: false,
        jointTailFlushOk: false,
        noProviderUnderrunOk: false,
        noZeroFillOk: false,
        noForwardSkipOk: false,
        noRewindRejectOk: false,
        noSilenceOk: false,
        noRingPushShortfallOk: false,
        zeroNativeSteadyStateAllocationOk: false,
        ownerThreadOk: false,
        lifecycleOk: false,
        canonical: false,
        sampleRate: 0,
        channelCount: 0,
        pcmEncoding: 0,
        commonBudgetFrames: 0,
        framesTruncatedBeyondBudget: 0,
        totalFramesExtracted: 0,
        totalFramesAcceptedTrack0: 0,
        totalFramesAcceptedTrack1: 0,
        totalOutputFramesDrained: 0,
        postSeekFramesAccepted: 0,
        postSeekFramesDrained: 0,
        seekAcceptedFrame: -1,
        track1NonZeroSampleCount: 0,
        mixedChecksumDiffersFromTrack0: false,
        mixedChecksumDiffersFromTrack1: false,
        decoderBenignFormatChangeCount: 0,
        providerUnderrunEventsTrack0: 0,
        providerUnderrunEventsTrack1: 0,
        providerFramesZeroFilledTrack0: 0,
        providerFramesZeroFilledTrack1: 0,
        providerForwardSkipFramesTrack0: 0,
        providerForwardSkipFramesTrack1: 0,
        providerRewindRejectsTrack0: 0,
        providerRewindRejectsTrack1: 0,
        coordinatorSilenceCount: 0,
        nativeAcceptedChecksumHexTrack0: '',
        nativeAcceptedChecksumHexTrack1: '',
        nativeOutputDrainChecksumHex: '',
        kotlinAcceptedChecksumHexTrack0: '',
        kotlinAcceptedChecksumHexTrack1: '',
        kotlinReferenceMixChecksumHex: '',
        maxFramesPerMix: 0,
        sourceAvailableReadFramesTrack0: -1,
        sourceAvailableReadFramesTrack1: -1,
        outputAvailableReadFrames: -1,
        dispatchCount: 0,
        nextDispatchFrame: -1,
        nativeLastStatus: '',
        lanes: <String, Object?>{
          'formatProbeOk': false,
          'topologyRoutedSourcesOk': false,
          'track0IngestOk': false,
          'track1SyntheticIngestOk': false,
          'trackFrameAxisLockstepOk': false,
          'jointDispatchGateOk': false,
          'referenceMixChecksumOk': false,
          'mixedOutputFrameAccountingOk': false,
          'twoTrackContributionOk': false,
          'seekOk': false,
          'jointTailFlushOk': false,
          'noProviderUnderrunOk': false,
          'noZeroFillOk': false,
          'noForwardSkipOk': false,
          'noRewindRejectOk': false,
          'noSilenceOk': false,
          'noRingPushShortfallOk': false,
          'zeroNativeSteadyStateAllocationOk': false,
          'ownerThreadOk': false,
          'lifecycleOk': false,
          'canonical': false,
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

    final formatProbeOk = parseBool('formatProbeOk');
    final topologyRoutedSourcesOk = parseBool('topologyRoutedSourcesOk');
    final track0IngestOk = parseBool('track0IngestOk');
    final track1SyntheticIngestOk = parseBool('track1SyntheticIngestOk');
    final trackFrameAxisLockstepOk = parseBool('trackFrameAxisLockstepOk');
    final jointDispatchGateOk = parseBool('jointDispatchGateOk');
    final referenceMixChecksumOk = parseBool('referenceMixChecksumOk');
    final mixedOutputFrameAccountingOk = parseBool(
      'mixedOutputFrameAccountingOk',
    );
    final twoTrackContributionOk = parseBool('twoTrackContributionOk');
    final seekOk = parseBool('seekOk');
    final jointTailFlushOk = parseBool('jointTailFlushOk');
    final noProviderUnderrunOk = parseBool('noProviderUnderrunOk');
    final noZeroFillOk = parseBool('noZeroFillOk');
    final noForwardSkipOk = parseBool('noForwardSkipOk');
    final noRewindRejectOk = parseBool('noRewindRejectOk');
    final noSilenceOk = parseBool('noSilenceOk');
    final noRingPushShortfallOk = parseBool('noRingPushShortfallOk');
    final zeroNativeSteadyStateAllocationOk = parseBool(
      'zeroNativeSteadyStateAllocationOk',
    );
    final ownerThreadOk = parseBool('ownerThreadOk');
    final lifecycleOk = parseBool('lifecycleOk');
    final canonical = parseBool('canonical', pass);

    final sampleRate = parseInt('sampleRate');
    final channelCount = parseInt('channelCount');
    final pcmEncoding = parseInt('pcmEncoding');
    final commonBudgetFrames = parseInt('commonBudgetFrames');
    final framesTruncatedBeyondBudget = parseInt('framesTruncatedBeyondBudget');
    final totalFramesExtracted = parseInt('totalFramesExtracted');
    final totalFramesAcceptedTrack0 = parseInt('totalFramesAcceptedTrack0');
    final totalFramesAcceptedTrack1 = parseInt('totalFramesAcceptedTrack1');
    final totalOutputFramesDrained = parseInt('totalOutputFramesDrained');
    final postSeekFramesAccepted = parseInt('postSeekFramesAccepted');
    final postSeekFramesDrained = parseInt('postSeekFramesDrained');
    final seekAcceptedFrame = parseInt('seekAcceptedFrame', -1);
    final track1NonZeroSampleCount = parseInt('track1NonZeroSampleCount');
    final mixedChecksumDiffersFromTrack0 = parseBool(
      'mixedChecksumDiffersFromTrack0',
    );
    final mixedChecksumDiffersFromTrack1 = parseBool(
      'mixedChecksumDiffersFromTrack1',
    );
    final decoderBenignFormatChangeCount = parseInt(
      'decoderBenignFormatChangeCount',
    );
    final providerUnderrunEventsTrack0 = parseInt(
      'providerUnderrunEventsTrack0',
    );
    final providerUnderrunEventsTrack1 = parseInt(
      'providerUnderrunEventsTrack1',
    );
    final providerFramesZeroFilledTrack0 = parseInt(
      'providerFramesZeroFilledTrack0',
    );
    final providerFramesZeroFilledTrack1 = parseInt(
      'providerFramesZeroFilledTrack1',
    );
    final providerForwardSkipFramesTrack0 = parseInt(
      'providerForwardSkipFramesTrack0',
    );
    final providerForwardSkipFramesTrack1 = parseInt(
      'providerForwardSkipFramesTrack1',
    );
    final providerRewindRejectsTrack0 = parseInt('providerRewindRejectsTrack0');
    final providerRewindRejectsTrack1 = parseInt('providerRewindRejectsTrack1');
    final coordinatorSilenceCount = parseInt('coordinatorSilenceCount');
    final nativeAcceptedChecksumHexTrack0 = parseString(
      'nativeAcceptedChecksumHexTrack0',
    );
    final nativeAcceptedChecksumHexTrack1 = parseString(
      'nativeAcceptedChecksumHexTrack1',
    );
    final nativeOutputDrainChecksumHex = parseString(
      'nativeOutputDrainChecksumHex',
    );
    final kotlinAcceptedChecksumHexTrack0 = parseString(
      'kotlinAcceptedChecksumHexTrack0',
    );
    final kotlinAcceptedChecksumHexTrack1 = parseString(
      'kotlinAcceptedChecksumHexTrack1',
    );
    final kotlinReferenceMixChecksumHex = parseString(
      'kotlinReferenceMixChecksumHex',
    );
    final maxFramesPerMix = parseInt('maxFramesPerMix');
    final sourceAvailableReadFramesTrack0 = parseInt(
      'sourceAvailableReadFramesTrack0',
      -1,
    );
    final sourceAvailableReadFramesTrack1 = parseInt(
      'sourceAvailableReadFramesTrack1',
      -1,
    );
    final outputAvailableReadFrames = parseInt('outputAvailableReadFrames', -1);
    final dispatchCount = parseInt('dispatchCount');
    final nextDispatchFrame = parseInt('nextDispatchFrame', -1);
    final nativeLastStatus = parseString('nativeLastStatus');

    final lastError = parseString(
      'lastError',
      failureReason.isNotEmpty ? failureReason : (pass ? '' : status),
    );

    final finalLanes = <String, Object?>{
      'formatProbeOk': formatProbeOk,
      'topologyRoutedSourcesOk': topologyRoutedSourcesOk,
      'track0IngestOk': track0IngestOk,
      'track1SyntheticIngestOk': track1SyntheticIngestOk,
      'trackFrameAxisLockstepOk': trackFrameAxisLockstepOk,
      'jointDispatchGateOk': jointDispatchGateOk,
      'referenceMixChecksumOk': referenceMixChecksumOk,
      'mixedOutputFrameAccountingOk': mixedOutputFrameAccountingOk,
      'twoTrackContributionOk': twoTrackContributionOk,
      'seekOk': seekOk,
      'jointTailFlushOk': jointTailFlushOk,
      'noProviderUnderrunOk': noProviderUnderrunOk,
      'noZeroFillOk': noZeroFillOk,
      'noForwardSkipOk': noForwardSkipOk,
      'noRewindRejectOk': noRewindRejectOk,
      'noSilenceOk': noSilenceOk,
      'noRingPushShortfallOk': noRingPushShortfallOk,
      'zeroNativeSteadyStateAllocationOk': zeroNativeSteadyStateAllocationOk,
      'ownerThreadOk': ownerThreadOk,
      'lifecycleOk': lifecycleOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{
      'sampleRate': sampleRate,
      'channelCount': channelCount,
      'pcmEncoding': pcmEncoding,
      'commonBudgetFrames': commonBudgetFrames,
      'framesTruncatedBeyondBudget': framesTruncatedBeyondBudget,
      'totalFramesExtracted': totalFramesExtracted,
      'totalFramesAcceptedTrack0': totalFramesAcceptedTrack0,
      'totalFramesAcceptedTrack1': totalFramesAcceptedTrack1,
      'totalOutputFramesDrained': totalOutputFramesDrained,
      'postSeekFramesAccepted': postSeekFramesAccepted,
      'postSeekFramesDrained': postSeekFramesDrained,
      'seekAcceptedFrame': seekAcceptedFrame,
      'track1NonZeroSampleCount': track1NonZeroSampleCount,
      'mixedChecksumDiffersFromTrack0': mixedChecksumDiffersFromTrack0,
      'mixedChecksumDiffersFromTrack1': mixedChecksumDiffersFromTrack1,
      'decoderBenignFormatChangeCount': decoderBenignFormatChangeCount,
      'providerUnderrunEventsTrack0': providerUnderrunEventsTrack0,
      'providerUnderrunEventsTrack1': providerUnderrunEventsTrack1,
      'providerFramesZeroFilledTrack0': providerFramesZeroFilledTrack0,
      'providerFramesZeroFilledTrack1': providerFramesZeroFilledTrack1,
      'providerForwardSkipFramesTrack0': providerForwardSkipFramesTrack0,
      'providerForwardSkipFramesTrack1': providerForwardSkipFramesTrack1,
      'providerRewindRejectsTrack0': providerRewindRejectsTrack0,
      'providerRewindRejectsTrack1': providerRewindRejectsTrack1,
      'coordinatorSilenceCount': coordinatorSilenceCount,
      'nativeAcceptedChecksumHexTrack0': nativeAcceptedChecksumHexTrack0,
      'nativeAcceptedChecksumHexTrack1': nativeAcceptedChecksumHexTrack1,
      'nativeOutputDrainChecksumHex': nativeOutputDrainChecksumHex,
      'kotlinAcceptedChecksumHexTrack0': kotlinAcceptedChecksumHexTrack0,
      'kotlinAcceptedChecksumHexTrack1': kotlinAcceptedChecksumHexTrack1,
      'kotlinReferenceMixChecksumHex': kotlinReferenceMixChecksumHex,
      'maxFramesPerMix': maxFramesPerMix,
      'sourceAvailableReadFramesTrack0': sourceAvailableReadFramesTrack0,
      'sourceAvailableReadFramesTrack1': sourceAvailableReadFramesTrack1,
      'outputAvailableReadFrames': outputAvailableReadFrames,
      'dispatchCount': dispatchCount,
      'nextDispatchFrame': nextDispatchFrame,
      'nativeLastStatus': nativeLastStatus,
      ...parsedMetrics,
    };

    return VGMultiSourceGraphPipelineSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      details: details,
      formatProbeOk: formatProbeOk,
      topologyRoutedSourcesOk: topologyRoutedSourcesOk,
      track0IngestOk: track0IngestOk,
      track1SyntheticIngestOk: track1SyntheticIngestOk,
      trackFrameAxisLockstepOk: trackFrameAxisLockstepOk,
      jointDispatchGateOk: jointDispatchGateOk,
      referenceMixChecksumOk: referenceMixChecksumOk,
      mixedOutputFrameAccountingOk: mixedOutputFrameAccountingOk,
      twoTrackContributionOk: twoTrackContributionOk,
      seekOk: seekOk,
      jointTailFlushOk: jointTailFlushOk,
      noProviderUnderrunOk: noProviderUnderrunOk,
      noZeroFillOk: noZeroFillOk,
      noForwardSkipOk: noForwardSkipOk,
      noRewindRejectOk: noRewindRejectOk,
      noSilenceOk: noSilenceOk,
      noRingPushShortfallOk: noRingPushShortfallOk,
      zeroNativeSteadyStateAllocationOk: zeroNativeSteadyStateAllocationOk,
      ownerThreadOk: ownerThreadOk,
      lifecycleOk: lifecycleOk,
      canonical: canonical,
      sampleRate: sampleRate,
      channelCount: channelCount,
      pcmEncoding: pcmEncoding,
      commonBudgetFrames: commonBudgetFrames,
      framesTruncatedBeyondBudget: framesTruncatedBeyondBudget,
      totalFramesExtracted: totalFramesExtracted,
      totalFramesAcceptedTrack0: totalFramesAcceptedTrack0,
      totalFramesAcceptedTrack1: totalFramesAcceptedTrack1,
      totalOutputFramesDrained: totalOutputFramesDrained,
      postSeekFramesAccepted: postSeekFramesAccepted,
      postSeekFramesDrained: postSeekFramesDrained,
      seekAcceptedFrame: seekAcceptedFrame,
      track1NonZeroSampleCount: track1NonZeroSampleCount,
      mixedChecksumDiffersFromTrack0: mixedChecksumDiffersFromTrack0,
      mixedChecksumDiffersFromTrack1: mixedChecksumDiffersFromTrack1,
      decoderBenignFormatChangeCount: decoderBenignFormatChangeCount,
      providerUnderrunEventsTrack0: providerUnderrunEventsTrack0,
      providerUnderrunEventsTrack1: providerUnderrunEventsTrack1,
      providerFramesZeroFilledTrack0: providerFramesZeroFilledTrack0,
      providerFramesZeroFilledTrack1: providerFramesZeroFilledTrack1,
      providerForwardSkipFramesTrack0: providerForwardSkipFramesTrack0,
      providerForwardSkipFramesTrack1: providerForwardSkipFramesTrack1,
      providerRewindRejectsTrack0: providerRewindRejectsTrack0,
      providerRewindRejectsTrack1: providerRewindRejectsTrack1,
      coordinatorSilenceCount: coordinatorSilenceCount,
      nativeAcceptedChecksumHexTrack0: nativeAcceptedChecksumHexTrack0,
      nativeAcceptedChecksumHexTrack1: nativeAcceptedChecksumHexTrack1,
      nativeOutputDrainChecksumHex: nativeOutputDrainChecksumHex,
      kotlinAcceptedChecksumHexTrack0: kotlinAcceptedChecksumHexTrack0,
      kotlinAcceptedChecksumHexTrack1: kotlinAcceptedChecksumHexTrack1,
      kotlinReferenceMixChecksumHex: kotlinReferenceMixChecksumHex,
      maxFramesPerMix: maxFramesPerMix,
      sourceAvailableReadFramesTrack0: sourceAvailableReadFramesTrack0,
      sourceAvailableReadFramesTrack1: sourceAvailableReadFramesTrack1,
      outputAvailableReadFrames: outputAvailableReadFrames,
      dispatchCount: dispatchCount,
      nextDispatchFrame: nextDispatchFrame,
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
      'lanes': Map<String, Object?>.from(lanes),
      'metrics': Map<String, Object?>.from(metrics),
      'raw': Map<String, String>.from(raw),
      'lastError': lastError,
    };
  }

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static VGMultiSourceGraphPipelineSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      'formatProbeOk': false,
      'topologyRoutedSourcesOk': false,
      'track0IngestOk': false,
      'track1SyntheticIngestOk': false,
      'trackFrameAxisLockstepOk': false,
      'jointDispatchGateOk': false,
      'referenceMixChecksumOk': false,
      'mixedOutputFrameAccountingOk': false,
      'twoTrackContributionOk': false,
      'seekOk': false,
      'jointTailFlushOk': false,
      'noProviderUnderrunOk': false,
      'noZeroFillOk': false,
      'noForwardSkipOk': false,
      'noRewindRejectOk': false,
      'noSilenceOk': false,
      'noRingPushShortfallOk': false,
      'zeroNativeSteadyStateAllocationOk': false,
      'ownerThreadOk': false,
      'lifecycleOk': false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'sampleRate': 0,
      'channelCount': 0,
      'pcmEncoding': 0,
      'commonBudgetFrames': 0,
      'framesTruncatedBeyondBudget': 0,
      'totalFramesExtracted': 0,
      'totalFramesAcceptedTrack0': 0,
      'totalFramesAcceptedTrack1': 0,
      'totalOutputFramesDrained': 0,
      'postSeekFramesAccepted': 0,
      'postSeekFramesDrained': 0,
      'seekAcceptedFrame': -1,
      'track1NonZeroSampleCount': 0,
      'mixedChecksumDiffersFromTrack0': false,
      'mixedChecksumDiffersFromTrack1': false,
      'decoderBenignFormatChangeCount': 0,
      'providerUnderrunEventsTrack0': 0,
      'providerUnderrunEventsTrack1': 0,
      'providerFramesZeroFilledTrack0': 0,
      'providerFramesZeroFilledTrack1': 0,
      'providerForwardSkipFramesTrack0': 0,
      'providerForwardSkipFramesTrack1': 0,
      'providerRewindRejectsTrack0': 0,
      'providerRewindRejectsTrack1': 0,
      'coordinatorSilenceCount': 0,
      'nativeAcceptedChecksumHexTrack0': '',
      'nativeAcceptedChecksumHexTrack1': '',
      'nativeOutputDrainChecksumHex': '',
      'kotlinAcceptedChecksumHexTrack0': '',
      'kotlinAcceptedChecksumHexTrack1': '',
      'kotlinReferenceMixChecksumHex': '',
      'maxFramesPerMix': 0,
      'sourceAvailableReadFramesTrack0': -1,
      'sourceAvailableReadFramesTrack1': -1,
      'outputAvailableReadFrames': -1,
      'dispatchCount': 0,
      'nextDispatchFrame': -1,
      'nativeLastStatus': '',
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGMultiSourceGraphPipelineSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      topologyRoutedSourcesOk: false,
      track0IngestOk: false,
      track1SyntheticIngestOk: false,
      trackFrameAxisLockstepOk: false,
      jointDispatchGateOk: false,
      referenceMixChecksumOk: false,
      mixedOutputFrameAccountingOk: false,
      twoTrackContributionOk: false,
      seekOk: false,
      jointTailFlushOk: false,
      noProviderUnderrunOk: false,
      noZeroFillOk: false,
      noForwardSkipOk: false,
      noRewindRejectOk: false,
      noSilenceOk: false,
      noRingPushShortfallOk: false,
      zeroNativeSteadyStateAllocationOk: false,
      ownerThreadOk: false,
      lifecycleOk: false,
      canonical: false,
      sampleRate: 0,
      channelCount: 0,
      pcmEncoding: 0,
      commonBudgetFrames: 0,
      framesTruncatedBeyondBudget: 0,
      totalFramesExtracted: 0,
      totalFramesAcceptedTrack0: 0,
      totalFramesAcceptedTrack1: 0,
      totalOutputFramesDrained: 0,
      postSeekFramesAccepted: 0,
      postSeekFramesDrained: 0,
      seekAcceptedFrame: -1,
      track1NonZeroSampleCount: 0,
      mixedChecksumDiffersFromTrack0: false,
      mixedChecksumDiffersFromTrack1: false,
      decoderBenignFormatChangeCount: 0,
      providerUnderrunEventsTrack0: 0,
      providerUnderrunEventsTrack1: 0,
      providerFramesZeroFilledTrack0: 0,
      providerFramesZeroFilledTrack1: 0,
      providerForwardSkipFramesTrack0: 0,
      providerForwardSkipFramesTrack1: 0,
      providerRewindRejectsTrack0: 0,
      providerRewindRejectsTrack1: 0,
      coordinatorSilenceCount: 0,
      nativeAcceptedChecksumHexTrack0: '',
      nativeAcceptedChecksumHexTrack1: '',
      nativeOutputDrainChecksumHex: '',
      kotlinAcceptedChecksumHexTrack0: '',
      kotlinAcceptedChecksumHexTrack1: '',
      kotlinReferenceMixChecksumHex: '',
      maxFramesPerMix: 0,
      sourceAvailableReadFramesTrack0: -1,
      sourceAvailableReadFramesTrack1: -1,
      outputAvailableReadFrames: -1,
      dispatchCount: 0,
      nextDispatchFrame: -1,
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

  /// Invokes the Android True-DAG Phase 4 two-source (real decoder + synthetic)
  /// closed-loop native audio graph pipeline diagnostic proof smoke harness.
  ///
  /// [sourcePath] path to the source audio/video media file (required).
  /// [durationSec] duration in seconds to process (default 1.0, max 2.0).
  /// [seekTargetSec] seek target position in seconds (default 0.35).
  /// [sourceRingCapacityFrames] capacity of source rings in frames (default 8192).
  /// [outputRingCapacityFrames] capacity of output ring in frames (default 4096).
  /// [maxFramesPerMix] max frames per mix dispatch cycle (default 256).
  /// [timeout] optionally bounds the invocation; deadlineMs is passed to Kotlin.
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGMultiSourceGraphPipelineSmokeReport>
  runAndroidDagPhase4MultiSourceGraphPipelineSmoke({
    required String sourcePath,
    double durationSec = 1.0,
    double seekTargetSec = 0.35,
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
      return VGMultiSourceGraphPipelineSmokeReport.fromMap(raw);
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
    return other is VGMultiSourceGraphPipelineSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.formatProbeOk == formatProbeOk &&
        other.topologyRoutedSourcesOk == topologyRoutedSourcesOk &&
        other.track0IngestOk == track0IngestOk &&
        other.track1SyntheticIngestOk == track1SyntheticIngestOk &&
        other.trackFrameAxisLockstepOk == trackFrameAxisLockstepOk &&
        other.jointDispatchGateOk == jointDispatchGateOk &&
        other.referenceMixChecksumOk == referenceMixChecksumOk &&
        other.mixedOutputFrameAccountingOk == mixedOutputFrameAccountingOk &&
        other.twoTrackContributionOk == twoTrackContributionOk &&
        other.seekOk == seekOk &&
        other.jointTailFlushOk == jointTailFlushOk &&
        other.noProviderUnderrunOk == noProviderUnderrunOk &&
        other.noZeroFillOk == noZeroFillOk &&
        other.noForwardSkipOk == noForwardSkipOk &&
        other.noRewindRejectOk == noRewindRejectOk &&
        other.noSilenceOk == noSilenceOk &&
        other.noRingPushShortfallOk == noRingPushShortfallOk &&
        other.zeroNativeSteadyStateAllocationOk ==
            zeroNativeSteadyStateAllocationOk &&
        other.ownerThreadOk == ownerThreadOk &&
        other.lifecycleOk == lifecycleOk &&
        other.canonical == canonical &&
        other.sampleRate == sampleRate &&
        other.channelCount == channelCount &&
        other.pcmEncoding == pcmEncoding &&
        other.commonBudgetFrames == commonBudgetFrames &&
        other.framesTruncatedBeyondBudget == framesTruncatedBeyondBudget &&
        other.totalFramesExtracted == totalFramesExtracted &&
        other.totalFramesAcceptedTrack0 == totalFramesAcceptedTrack0 &&
        other.totalFramesAcceptedTrack1 == totalFramesAcceptedTrack1 &&
        other.totalOutputFramesDrained == totalOutputFramesDrained &&
        other.postSeekFramesAccepted == postSeekFramesAccepted &&
        other.postSeekFramesDrained == postSeekFramesDrained &&
        other.seekAcceptedFrame == seekAcceptedFrame &&
        other.track1NonZeroSampleCount == track1NonZeroSampleCount &&
        other.mixedChecksumDiffersFromTrack0 ==
            mixedChecksumDiffersFromTrack0 &&
        other.mixedChecksumDiffersFromTrack1 ==
            mixedChecksumDiffersFromTrack1 &&
        other.decoderBenignFormatChangeCount ==
            decoderBenignFormatChangeCount &&
        other.providerUnderrunEventsTrack0 == providerUnderrunEventsTrack0 &&
        other.providerUnderrunEventsTrack1 == providerUnderrunEventsTrack1 &&
        other.providerFramesZeroFilledTrack0 ==
            providerFramesZeroFilledTrack0 &&
        other.providerFramesZeroFilledTrack1 ==
            providerFramesZeroFilledTrack1 &&
        other.providerForwardSkipFramesTrack0 ==
            providerForwardSkipFramesTrack0 &&
        other.providerForwardSkipFramesTrack1 ==
            providerForwardSkipFramesTrack1 &&
        other.providerRewindRejectsTrack0 == providerRewindRejectsTrack0 &&
        other.providerRewindRejectsTrack1 == providerRewindRejectsTrack1 &&
        other.coordinatorSilenceCount == coordinatorSilenceCount &&
        other.nativeAcceptedChecksumHexTrack0 ==
            nativeAcceptedChecksumHexTrack0 &&
        other.nativeAcceptedChecksumHexTrack1 ==
            nativeAcceptedChecksumHexTrack1 &&
        other.nativeOutputDrainChecksumHex == nativeOutputDrainChecksumHex &&
        other.kotlinAcceptedChecksumHexTrack0 ==
            kotlinAcceptedChecksumHexTrack0 &&
        other.kotlinAcceptedChecksumHexTrack1 ==
            kotlinAcceptedChecksumHexTrack1 &&
        other.kotlinReferenceMixChecksumHex == kotlinReferenceMixChecksumHex &&
        other.maxFramesPerMix == maxFramesPerMix &&
        other.sourceAvailableReadFramesTrack0 ==
            sourceAvailableReadFramesTrack0 &&
        other.sourceAvailableReadFramesTrack1 ==
            sourceAvailableReadFramesTrack1 &&
        other.outputAvailableReadFrames == outputAvailableReadFrames &&
        other.dispatchCount == dispatchCount &&
        other.nextDispatchFrame == nextDispatchFrame &&
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
    formatProbeOk,
    topologyRoutedSourcesOk,
    track0IngestOk,
    track1SyntheticIngestOk,
    trackFrameAxisLockstepOk,
    jointDispatchGateOk,
    referenceMixChecksumOk,
    mixedOutputFrameAccountingOk,
    twoTrackContributionOk,
    seekOk,
    jointTailFlushOk,
    noProviderUnderrunOk,
    noZeroFillOk,
    noForwardSkipOk,
    noRewindRejectOk,
    noSilenceOk,
    noRingPushShortfallOk,
    zeroNativeSteadyStateAllocationOk,
    ownerThreadOk,
    lifecycleOk,
    canonical,
    sampleRate,
    channelCount,
    pcmEncoding,
    commonBudgetFrames,
    framesTruncatedBeyondBudget,
    totalFramesExtracted,
    totalFramesAcceptedTrack0,
    totalFramesAcceptedTrack1,
    totalOutputFramesDrained,
    postSeekFramesAccepted,
    postSeekFramesDrained,
    seekAcceptedFrame,
    track1NonZeroSampleCount,
    mixedChecksumDiffersFromTrack0,
    mixedChecksumDiffersFromTrack1,
    decoderBenignFormatChangeCount,
    providerUnderrunEventsTrack0,
    providerUnderrunEventsTrack1,
    providerFramesZeroFilledTrack0,
    providerFramesZeroFilledTrack1,
    providerForwardSkipFramesTrack0,
    providerForwardSkipFramesTrack1,
    providerRewindRejectsTrack0,
    providerRewindRejectsTrack1,
    coordinatorSilenceCount,
    nativeAcceptedChecksumHexTrack0,
    nativeAcceptedChecksumHexTrack1,
    nativeOutputDrainChecksumHex,
    kotlinAcceptedChecksumHexTrack0,
    kotlinAcceptedChecksumHexTrack1,
    kotlinReferenceMixChecksumHex,
    maxFramesPerMix,
    sourceAvailableReadFramesTrack0,
    sourceAvailableReadFramesTrack1,
    outputAvailableReadFrames,
    dispatchCount,
    nextDispatchFrame,
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
      'VGMultiSourceGraphPipelineSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'formatProbeOk: $formatProbeOk, '
      'topologyRoutedSourcesOk: $topologyRoutedSourcesOk, '
      'track0IngestOk: $track0IngestOk, '
      'track1SyntheticIngestOk: $track1SyntheticIngestOk, '
      'trackFrameAxisLockstepOk: $trackFrameAxisLockstepOk, '
      'jointDispatchGateOk: $jointDispatchGateOk, '
      'referenceMixChecksumOk: $referenceMixChecksumOk, '
      'mixedOutputFrameAccountingOk: $mixedOutputFrameAccountingOk, '
      'twoTrackContributionOk: $twoTrackContributionOk, '
      'seekOk: $seekOk, '
      'jointTailFlushOk: $jointTailFlushOk, '
      'noProviderUnderrunOk: $noProviderUnderrunOk, '
      'noZeroFillOk: $noZeroFillOk, '
      'noForwardSkipOk: $noForwardSkipOk, '
      'noRewindRejectOk: $noRewindRejectOk, '
      'noSilenceOk: $noSilenceOk, '
      'noRingPushShortfallOk: $noRingPushShortfallOk, '
      'zeroNativeSteadyStateAllocationOk: $zeroNativeSteadyStateAllocationOk, '
      'ownerThreadOk: $ownerThreadOk, '
      'lifecycleOk: $lifecycleOk, '
      'canonical: $canonical, '
      'sampleRate: $sampleRate, '
      'channelCount: $channelCount, '
      'pcmEncoding: $pcmEncoding, '
      'commonBudgetFrames: $commonBudgetFrames, '
      'framesTruncatedBeyondBudget: $framesTruncatedBeyondBudget, '
      'totalFramesExtracted: $totalFramesExtracted, '
      'totalFramesAcceptedTrack0: $totalFramesAcceptedTrack0, '
      'totalFramesAcceptedTrack1: $totalFramesAcceptedTrack1, '
      'totalOutputFramesDrained: $totalOutputFramesDrained, '
      'postSeekFramesAccepted: $postSeekFramesAccepted, '
      'postSeekFramesDrained: $postSeekFramesDrained, '
      'seekAcceptedFrame: $seekAcceptedFrame, '
      'track1NonZeroSampleCount: $track1NonZeroSampleCount, '
      'mixedChecksumDiffersFromTrack0: $mixedChecksumDiffersFromTrack0, '
      'mixedChecksumDiffersFromTrack1: $mixedChecksumDiffersFromTrack1, '
      'decoderBenignFormatChangeCount: $decoderBenignFormatChangeCount, '
      'providerUnderrunEventsTrack0: $providerUnderrunEventsTrack0, '
      'providerUnderrunEventsTrack1: $providerUnderrunEventsTrack1, '
      'providerFramesZeroFilledTrack0: $providerFramesZeroFilledTrack0, '
      'providerFramesZeroFilledTrack1: $providerFramesZeroFilledTrack1, '
      'providerForwardSkipFramesTrack0: $providerForwardSkipFramesTrack0, '
      'providerForwardSkipFramesTrack1: $providerForwardSkipFramesTrack1, '
      'providerRewindRejectsTrack0: $providerRewindRejectsTrack0, '
      'providerRewindRejectsTrack1: $providerRewindRejectsTrack1, '
      'coordinatorSilenceCount: $coordinatorSilenceCount, '
      'nativeAcceptedChecksumHexTrack0: $nativeAcceptedChecksumHexTrack0, '
      'nativeAcceptedChecksumHexTrack1: $nativeAcceptedChecksumHexTrack1, '
      'nativeOutputDrainChecksumHex: $nativeOutputDrainChecksumHex, '
      'kotlinAcceptedChecksumHexTrack0: $kotlinAcceptedChecksumHexTrack0, '
      'kotlinAcceptedChecksumHexTrack1: $kotlinAcceptedChecksumHexTrack1, '
      'kotlinReferenceMixChecksumHex: $kotlinReferenceMixChecksumHex, '
      'maxFramesPerMix: $maxFramesPerMix, '
      'sourceAvailableReadFramesTrack0: $sourceAvailableReadFramesTrack0, '
      'sourceAvailableReadFramesTrack1: $sourceAvailableReadFramesTrack1, '
      'outputAvailableReadFrames: $outputAvailableReadFrames, '
      'dispatchCount: $dispatchCount, '
      'nextDispatchFrame: $nextDispatchFrame, '
      'nativeLastStatus: $nativeLastStatus, '
      'lanes: $lanes, '
      'metrics: $metrics, '
      'raw: $raw, '
      'lastError: $lastError)';
}
