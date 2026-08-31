// vg_node_owned_sink_clocked_transport_smoke.dart
// vanguard_media_engine - P4-AUDIO-NODE-OWNED-SINK-CLOCKED-TRANSPORT: Android True-DAG Phase 4
// node-owned AudioTrack sink-clocked transport diagnostic smoke foundation
// (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke` MethodChannel route.
// Diagnostic-only - validates the real MediaExtractor/MediaCodec decode driving
// the node-owned DecodedAudioPcmSourceNode closed-loop native audio graph pipeline
// with muted android.media.AudioTrack MODE_STREAM sink egress via
// readNodeOwnedAudioSourceGraphPipelineOutputPcm16 and the AudioTrack as Kotlin
// timebase master after pre-roll.
//
// Honest non-claims (Proof Boundary):
// kotlin_owned_android_audiotrack_node_owned_source_sink_clocked_transport_diagnostic_proof_only_real_decoder_to_node_owned_decoded_audio_source_graph_pipeline_output_ring_to_audiotrack_write_accounting_sink_clocked_timebase_audio_timestamp_conditional_playback_head_fallback_system_nanotime_anchor_kotlin_only_no_cpp_wall_clock_read_no_native_audio_sink_no_aaudio_no_opensl_no_oboe_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_av_sync_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_dead_object_recovery_no_offload_no_low_latency_mode_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_streaming_no_cache_no_ios_single_routed_track_unit_gain_only_no_resample_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_no_jni_reverse_callbacks_no_native_worker_threads_jni_session_registry_mutex_lifecycle_only_no_locks_in_vanguard_audio_primitives_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGNodeOwnedSinkClockedTransportSmokeReport.runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGNodeOwnedSinkClockedTransportSmokeReport {
  const VGNodeOwnedSinkClockedTransportSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.audioTrackInitOk,
    required this.mutedOutputOk,
    required this.nodeOwnedRouteDiscoveryOk,
    required this.nodeOwnsRingOk,
    required this.startAckOk,
    required this.sinkClockedDispatchOk,
    required this.timestampTelemetryOk,
    required this.playbackHeadMonotonicOk,
    required this.playbackHeadAdvancedOk,
    required this.sinkWriteAccountingOk,
    required this.checksumIdentityOk,
    required this.frameAccountingOk,
    required this.seekOk,
    required this.tailFlushOk,
    required this.steadyStateUnderrunFreeOk,
    required this.noProviderUnderrunOk,
    required this.noSilenceOk,
    required this.noForwardSkipOk,
    required this.noRewindRejectOk,
    required this.finalNotTerminalOk,
    required this.finalSeekAckClearOk,
    required this.zeroNativeSteadyStateAllocationOk,
    required this.cancellationPollingOk,
    required this.lifecycleOk,
    required this.canonical,
    required this.sampleRate,
    required this.channelCount,
    required this.pcmEncoding,
    required this.expectedFrameCount,
    required this.totalFramesExtracted,
    required this.totalFramesAccepted,
    required this.totalOutputFramesDrained,
    required this.framesReadFromRingTotal,
    required this.framesWrittenTotal,
    required this.postSeekFramesAccepted,
    required this.postSeekFramesDrained,
    required this.nativeAcceptedChecksumHex,
    required this.nativeOutputDrainChecksumHex,
    required this.kotlinSinkChecksumHex,
    required this.dispatchCount,
    required this.maxFramesPerMix,
    required this.sourceAvailableReadFrames,
    required this.outputAvailableReadFrames,
    required this.nextDispatchFrame,
    required this.bootstrapDispatchCount,
    required this.sinkClockedDispatchCountEpoch0,
    required this.sinkClockedDispatchCountEpoch1,
    required this.prerollFrames,
    required this.targetLeadFrames,
    required this.bufferSizeInFrames,
    required this.bufferCapacityInFrames,
    required this.startThresholdFrames,
    required this.audioTimestampAttemptCount,
    required this.audioTimestampSuccessCount,
    required this.headSampleCount,
    required this.playbackHeadFinal,
    required this.maxSinkLagFrames,
    required this.maxDispatchLeadFrames,
    required this.minDispatchLeadFrames,
    required this.underrunBaseline,
    required this.underrunFinal,
    required this.underrunDelta,
    required this.zeroWriteCount,
    required this.partialWriteCount,
    required this.audioTrackReleaseCount,
    required this.nativeDestroyCallCount,
    required this.seekAcceptedFrame,
    required this.providerUnderrunEvents,
    required this.providerFramesZeroFilled,
    required this.providerForwardSkipFrames,
    required this.providerRewindRejects,
    required this.coordinatorSilenceCount,
    required this.cancellationPollCount,
    required this.lanes,
    required this.metrics,
    required this.raw,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'kotlin_owned_android_audiotrack_node_owned_source_sink_clocked_transport_diagnostic_proof_only_real_decoder_to_node_owned_decoded_audio_source_graph_pipeline_output_ring_to_audiotrack_write_accounting_sink_clocked_timebase_audio_timestamp_conditional_playback_head_fallback_system_nanotime_anchor_kotlin_only_no_cpp_wall_clock_read_no_native_audio_sink_no_aaudio_no_opensl_no_oboe_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_av_sync_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_dead_object_recovery_no_offload_no_low_latency_mode_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_streaming_no_cache_no_ios_single_routed_track_unit_gain_only_no_resample_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_no_jni_reverse_callbacks_no_native_worker_threads_jni_session_registry_mutex_lifecycle_only_no_locks_in_vanguard_audio_primitives_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim';

  /// Expected source node ID string in topology.
  static const String expectedSourceNodeId = 'node_owned_pipeline_src';

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

  // ---- Lanes (26 hard lanes) -----------------------------------------------

  /// Whether initial audio format probe succeeded (PCM16, 1..2 channels).
  final bool formatProbeOk;

  /// Whether muted AudioTrack was created and initialized in STATE_INITIALIZED.
  final bool audioTrackInitOk;

  /// Whether AudioTrack volume was explicitly set to 0.0f (muted).
  final bool mutedOutputOk;

  /// Whether scheduler auto-discovered the single node-owned source from topology.
  final bool nodeOwnedRouteDiscoveryOk;

  /// Whether DecodedAudioPcmSourceNode owns the ring/writer/provider triple.
  final bool nodeOwnsRingOk;

  /// Whether start ACK was consumed cleanly with zero discards.
  final bool startAckOk;

  /// Whether sink-clocked dispatch occurred in both epochs with valid lead.
  final bool sinkClockedDispatchOk;

  /// Whether AudioTimestamp telemetry was valid or safely unavailable.
  final bool timestampTelemetryOk;

  /// Whether raw playback head advanced monotonically without regression.
  final bool playbackHeadMonotonicOk;

  /// Whether raw playback head advanced beyond 0 by the end of the run.
  final bool playbackHeadAdvancedOk;

  /// Whether frames read from output ring strictly match frames written to sink across epochs.
  final bool sinkWriteAccountingOk;

  /// Whether 3-way checksum identity holds (native accepted == native drained == Kotlin sink).
  final bool checksumIdentityOk;

  /// Whether total frames accepted == total output drained == frames written.
  final bool frameAccountingOk;

  /// Whether seek boundary re-based cursor with zero discards.
  final bool seekOk;

  /// Whether tail flush steps advanced and completed cleanly across epochs.
  final bool tailFlushOk;

  /// Whether native provider/coordinator steady state remained underrun-free across captured epochs.
  final bool steadyStateUnderrunFreeOk;

  /// Whether no provider underruns occurred.
  final bool noProviderUnderrunOk;

  /// Whether no coordinator silence windows occurred.
  final bool noSilenceOk;

  /// Whether no forward frame skip errors occurred.
  final bool noForwardSkipOk;

  /// Whether no rewind frame rejects occurred.
  final bool noRewindRejectOk;

  /// Whether final session state was non-terminal.
  final bool finalNotTerminalOk;

  /// Whether seek ACK was properly cleared in final state.
  final bool finalSeekAckClearOk;

  /// Whether ring and scheduler capacities remained constant across dispatches.
  final bool zeroNativeSteadyStateAllocationOk;

  /// Whether cancellation polling occurred across loops.
  final bool cancellationPollingOk;

  /// Whether session lifecycle creation, rejection, and destroy were idempotent.
  final bool lifecycleOk;

  /// Canonical pass indicator.
  final bool canonical;

  // ---- Metrics (48 metrics) -----------------------------------------------

  /// Resolved sampling rate in Hz.
  final int sampleRate;

  /// Resolved channel count (1 or 2).
  final int channelCount;

  /// Resolved PCM encoding (AudioFormat.ENCODING_PCM_16BIT = 2).
  final int pcmEncoding;

  /// Expected frame count configured on the node-owned source node.
  final int expectedFrameCount;

  /// Total frames extracted from MediaExtractor.
  final int totalFramesExtracted;

  /// Total frames accepted into the pipeline.
  final int totalFramesAccepted;

  /// Total frames drained from the output ring.
  final int totalOutputFramesDrained;

  /// Total frames read from output ring through sink buffer.
  final int framesReadFromRingTotal;

  /// Total frames written to AudioTrack sink.
  final int framesWrittenTotal;

  /// Total frames accepted after the forward seek boundary.
  final int postSeekFramesAccepted;

  /// Total frames drained after the forward seek boundary.
  final int postSeekFramesDrained;

  /// 64-bit hexadecimal checksum computed on the native accepted side.
  final String nativeAcceptedChecksumHex;

  /// 64-bit hexadecimal checksum computed on the native output drain side.
  final String nativeOutputDrainChecksumHex;

  /// 64-bit hexadecimal checksum computed on the Kotlin AudioTrack sink side.
  final String kotlinSinkChecksumHex;

  /// Total dispatch cycles executed during the run.
  final int dispatchCount;

  /// Maximum frames rendered per mix dispatch cycle.
  final int maxFramesPerMix;

  /// Source ring available read frames at last snapshot.
  final int sourceAvailableReadFrames;

  /// Output ring available read frames at last snapshot.
  final int outputAvailableReadFrames;

  /// Next dispatch frame index.
  final int nextDispatchFrame;

  /// Count of virtual bootstrap dispatches before play().
  final int bootstrapDispatchCount;

  /// Count of sink-clocked dispatches in epoch 0 (pre-seek).
  final int sinkClockedDispatchCountEpoch0;

  /// Count of sink-clocked dispatches in epoch 1 (post-seek).
  final int sinkClockedDispatchCountEpoch1;

  /// Pre-roll frame quota before play().
  final int prerollFrames;

  /// Target lead frame quota for the sink clock.
  final int targetLeadFrames;

  /// AudioTrack buffer size in frames.
  final int bufferSizeInFrames;

  /// AudioTrack buffer capacity in frames.
  final int bufferCapacityInFrames;

  /// AudioTrack start threshold in frames.
  final int startThresholdFrames;

  /// Number of AudioTimestamp query attempts.
  final int audioTimestampAttemptCount;

  /// Number of successful AudioTimestamp queries.
  final int audioTimestampSuccessCount;

  /// Number of playback head samples taken.
  final int headSampleCount;

  /// Final raw playback head position in frames.
  final int playbackHeadFinal;

  /// Maximum observed sink lag in frames.
  final int maxSinkLagFrames;

  /// Maximum observed dispatch lead in frames.
  final int maxDispatchLeadFrames;

  /// Minimum observed dispatch lead in frames.
  final int minDispatchLeadFrames;

  /// Underrun baseline captured at initial play().
  final int underrunBaseline;

  /// Final underrun count at epoch close.
  final int underrunFinal;

  /// Post-play device AudioTrack.underrunCount delta across all epochs (telemetry only).
  final int underrunDelta;

  /// Number of zero-byte write occurrences to AudioTrack.
  final int zeroWriteCount;

  /// Number of partial write occurrences to AudioTrack.
  final int partialWriteCount;

  /// AudioTrack release count (must be exactly 1).
  final int audioTrackReleaseCount;

  /// Idempotent native session destroy call count (must be >= 2).
  final int nativeDestroyCallCount;

  /// Frame index where seek was accepted.
  final int seekAcceptedFrame;

  /// Provider underrun events count (must be 0).
  final int providerUnderrunEvents;

  /// Provider frames zero-filled count (must be 0).
  final int providerFramesZeroFilled;

  /// Provider forward skip frames count (must be 0).
  final int providerForwardSkipFrames;

  /// Provider rewind frame rejects count (must be 0).
  final int providerRewindRejects;

  /// Coordinator silence windows count (must be 0).
  final int coordinatorSilenceCount;

  /// Cancellation poll count across loops.
  final int cancellationPollCount;

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

  /// Whether Kotlin sink, native accepted, and native output drain checksums
  /// are non-empty and equal, and [checksumIdentityOk] is true.
  bool get checksumsMatch =>
      kotlinSinkChecksumHex.isNotEmpty &&
      nativeAcceptedChecksumHex.isNotEmpty &&
      nativeOutputDrainChecksumHex.isNotEmpty &&
      kotlinSinkChecksumHex == nativeAcceptedChecksumHex &&
      nativeAcceptedChecksumHex == nativeOutputDrainChecksumHex &&
      checksumIdentityOk;

  /// Whether frame accounting across native accepted, output drained,
  /// ring read, and sink write holds strictly.
  bool get sinkFramesAccounted =>
      totalFramesAccepted > 0 &&
      totalFramesAccepted == totalOutputFramesDrained &&
      totalOutputFramesDrained == framesReadFromRingTotal &&
      framesReadFromRingTotal == framesWrittenTotal &&
      sinkWriteAccountingOk &&
      frameAccountingOk;

  /// Whether all native diagnostic lanes passed according to the
  /// P4-AUDIO-NODE-OWNED-SINK-CLOCKED-TRANSPORT verification contract.
  bool get allNativeLanesPass =>
      pass &&
      status.toLowerCase() == 'pass' &&
      marker == passMarkerConstant &&
      hasCanonicalProofBoundary &&
      formatProbeOk &&
      audioTrackInitOk &&
      mutedOutputOk &&
      nodeOwnedRouteDiscoveryOk &&
      nodeOwnsRingOk &&
      startAckOk &&
      sinkClockedDispatchOk &&
      timestampTelemetryOk &&
      playbackHeadMonotonicOk &&
      playbackHeadAdvancedOk &&
      sinkWriteAccountingOk &&
      checksumIdentityOk &&
      frameAccountingOk &&
      seekOk &&
      tailFlushOk &&
      steadyStateUnderrunFreeOk &&
      noProviderUnderrunOk &&
      noSilenceOk &&
      noForwardSkipOk &&
      noRewindRejectOk &&
      finalNotTerminalOk &&
      finalSeekAckClearOk &&
      zeroNativeSteadyStateAllocationOk &&
      cancellationPollingOk &&
      lifecycleOk &&
      canonical &&
      checksumsMatch &&
      sinkFramesAccounted &&
      sampleRate > 0 &&
      channelCount > 0 &&
      expectedFrameCount > 0 &&
      totalFramesAccepted > 0 &&
      totalOutputFramesDrained > 0 &&
      framesReadFromRingTotal > 0 &&
      framesWrittenTotal > 0 &&
      postSeekFramesAccepted > 0 &&
      postSeekFramesDrained > 0 &&
      playbackHeadFinal > 0 &&
      dispatchCount > 0 &&
      sinkClockedDispatchCountEpoch0 > 0 &&
      sinkClockedDispatchCountEpoch1 > 0 &&
      audioTrackReleaseCount == 1 &&
      nativeDestroyCallCount >= 2 &&
      cancellationPollCount > 0 &&
      maxFramesPerMix > 0 &&
      providerUnderrunEvents == 0 &&
      providerFramesZeroFilled == 0 &&
      providerForwardSkipFrames == 0 &&
      providerRewindRejects == 0 &&
      coordinatorSilenceCount == 0 &&
      sourceAvailableReadFrames == 0 &&
      outputAvailableReadFrames == 0 &&
      (lastError.isEmpty || lastError == 'none' || lastError == 'null');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGNodeOwnedSinkClockedTransportSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGNodeOwnedSinkClockedTransportSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        formatProbeOk: false,
        audioTrackInitOk: false,
        mutedOutputOk: false,
        nodeOwnedRouteDiscoveryOk: false,
        nodeOwnsRingOk: false,
        startAckOk: false,
        sinkClockedDispatchOk: false,
        timestampTelemetryOk: false,
        playbackHeadMonotonicOk: false,
        playbackHeadAdvancedOk: false,
        sinkWriteAccountingOk: false,
        checksumIdentityOk: false,
        frameAccountingOk: false,
        seekOk: false,
        tailFlushOk: false,
        steadyStateUnderrunFreeOk: false,
        noProviderUnderrunOk: false,
        noSilenceOk: false,
        noForwardSkipOk: false,
        noRewindRejectOk: false,
        finalNotTerminalOk: false,
        finalSeekAckClearOk: false,
        zeroNativeSteadyStateAllocationOk: false,
        cancellationPollingOk: false,
        lifecycleOk: false,
        canonical: false,
        sampleRate: 0,
        channelCount: 0,
        pcmEncoding: 0,
        expectedFrameCount: 0,
        totalFramesExtracted: 0,
        totalFramesAccepted: 0,
        totalOutputFramesDrained: 0,
        framesReadFromRingTotal: 0,
        framesWrittenTotal: 0,
        postSeekFramesAccepted: 0,
        postSeekFramesDrained: 0,
        nativeAcceptedChecksumHex: '',
        nativeOutputDrainChecksumHex: '',
        kotlinSinkChecksumHex: '',
        dispatchCount: 0,
        maxFramesPerMix: 0,
        sourceAvailableReadFrames: -1,
        outputAvailableReadFrames: -1,
        nextDispatchFrame: -1,
        bootstrapDispatchCount: 0,
        sinkClockedDispatchCountEpoch0: 0,
        sinkClockedDispatchCountEpoch1: 0,
        prerollFrames: 0,
        targetLeadFrames: 0,
        bufferSizeInFrames: 0,
        bufferCapacityInFrames: 0,
        startThresholdFrames: -1,
        audioTimestampAttemptCount: 0,
        audioTimestampSuccessCount: 0,
        headSampleCount: 0,
        playbackHeadFinal: 0,
        maxSinkLagFrames: -1,
        maxDispatchLeadFrames: -1,
        minDispatchLeadFrames: -1,
        underrunBaseline: -1,
        underrunFinal: -1,
        underrunDelta: 0,
        zeroWriteCount: 0,
        partialWriteCount: 0,
        audioTrackReleaseCount: 0,
        nativeDestroyCallCount: 0,
        seekAcceptedFrame: -1,
        providerUnderrunEvents: -1,
        providerFramesZeroFilled: -1,
        providerForwardSkipFrames: -1,
        providerRewindRejects: -1,
        coordinatorSilenceCount: -1,
        cancellationPollCount: 0,
        lanes: <String, Object?>{
          'formatProbeOk': false,
          'audioTrackInitOk': false,
          'mutedOutputOk': false,
          'nodeOwnedRouteDiscoveryOk': false,
          'nodeOwnsRingOk': false,
          'startAckOk': false,
          'sinkClockedDispatchOk': false,
          'timestampTelemetryOk': false,
          'playbackHeadMonotonicOk': false,
          'playbackHeadAdvancedOk': false,
          'sinkWriteAccountingOk': false,
          'checksumIdentityOk': false,
          'frameAccountingOk': false,
          'seekOk': false,
          'tailFlushOk': false,
          'steadyStateUnderrunFreeOk': false,
          'noProviderUnderrunOk': false,
          'noSilenceOk': false,
          'noForwardSkipOk': false,
          'noRewindRejectOk': false,
          'finalNotTerminalOk': false,
          'finalSeekAckClearOk': false,
          'zeroNativeSteadyStateAllocationOk': false,
          'cancellationPollingOk': false,
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
    final audioTrackInitOk = parseBool('audioTrackInitOk');
    final mutedOutputOk = parseBool('mutedOutputOk');
    final nodeOwnedRouteDiscoveryOk = parseBool('nodeOwnedRouteDiscoveryOk');
    final nodeOwnsRingOk = parseBool('nodeOwnsRingOk');
    final startAckOk = parseBool('startAckOk');
    final sinkClockedDispatchOk = parseBool('sinkClockedDispatchOk');
    final timestampTelemetryOk = parseBool('timestampTelemetryOk');
    final playbackHeadMonotonicOk = parseBool('playbackHeadMonotonicOk');
    final playbackHeadAdvancedOk = parseBool('playbackHeadAdvancedOk');
    final sinkWriteAccountingOk = parseBool('sinkWriteAccountingOk');
    final checksumIdentityOk = parseBool('checksumIdentityOk');
    final frameAccountingOk = parseBool('frameAccountingOk');
    final seekOk = parseBool('seekOk');
    final tailFlushOk = parseBool('tailFlushOk');
    final steadyStateUnderrunFreeOk = parseBool('steadyStateUnderrunFreeOk');
    final noProviderUnderrunOk = parseBool('noProviderUnderrunOk');
    final noSilenceOk = parseBool('noSilenceOk');
    final noForwardSkipOk = parseBool('noForwardSkipOk');
    final noRewindRejectOk = parseBool('noRewindRejectOk');
    final finalNotTerminalOk = parseBool('finalNotTerminalOk');
    final finalSeekAckClearOk = parseBool('finalSeekAckClearOk');
    final zeroNativeSteadyStateAllocationOk = parseBool(
      'zeroNativeSteadyStateAllocationOk',
    );
    final cancellationPollingOk = parseBool('cancellationPollingOk');
    final lifecycleOk = parseBool('lifecycleOk');
    final canonical = parseBool('canonical', pass);

    final sampleRate = parseInt('sampleRate');
    final channelCount = parseInt('channelCount');
    final pcmEncoding = parseInt('pcmEncoding');
    final expectedFrameCount = parseInt('expectedFrameCount');
    final totalFramesExtracted = parseInt('totalFramesExtracted');
    final totalFramesAccepted = parseInt('totalFramesAccepted');
    final totalOutputFramesDrained = parseInt('totalOutputFramesDrained');
    final framesReadFromRingTotal = parseInt('framesReadFromRingTotal');
    final framesWrittenTotal = parseInt('framesWrittenTotal');
    final postSeekFramesAccepted = parseInt('postSeekFramesAccepted');
    final postSeekFramesDrained = parseInt('postSeekFramesDrained');
    final nativeAcceptedChecksumHex = parseString('nativeAcceptedChecksumHex');
    final nativeOutputDrainChecksumHex = parseString(
      'nativeOutputDrainChecksumHex',
    );
    final kotlinSinkChecksumHex = parseString('kotlinSinkChecksumHex');
    final dispatchCount = parseInt('dispatchCount');
    final maxFramesPerMix = parseInt('maxFramesPerMix');
    final sourceAvailableReadFrames = parseInt('sourceAvailableReadFrames', -1);
    final outputAvailableReadFrames = parseInt('outputAvailableReadFrames', -1);
    final nextDispatchFrame = parseInt('nextDispatchFrame', -1);
    final bootstrapDispatchCount = parseInt('bootstrapDispatchCount');
    final sinkClockedDispatchCountEpoch0 = parseInt(
      'sinkClockedDispatchCountEpoch0',
    );
    final sinkClockedDispatchCountEpoch1 = parseInt(
      'sinkClockedDispatchCountEpoch1',
    );
    final prerollFrames = parseInt('prerollFrames');
    final targetLeadFrames = parseInt('targetLeadFrames');
    final bufferSizeInFrames = parseInt('bufferSizeInFrames');
    final bufferCapacityInFrames = parseInt('bufferCapacityInFrames');
    final startThresholdFrames = parseInt('startThresholdFrames', -1);
    final audioTimestampAttemptCount = parseInt('audioTimestampAttemptCount');
    final audioTimestampSuccessCount = parseInt('audioTimestampSuccessCount');
    final headSampleCount = parseInt('headSampleCount');
    final playbackHeadFinal = parseInt('playbackHeadFinal');
    final maxSinkLagFrames = parseInt('maxSinkLagFrames', -1);
    final maxDispatchLeadFrames = parseInt('maxDispatchLeadFrames', -1);
    final minDispatchLeadFrames = parseInt('minDispatchLeadFrames', -1);
    final underrunBaseline = parseInt('underrunBaseline', -1);
    final underrunFinal = parseInt('underrunFinal', -1);
    final underrunDelta = parseInt('underrunDelta');
    final zeroWriteCount = parseInt('zeroWriteCount');
    final partialWriteCount = parseInt('partialWriteCount');
    final audioTrackReleaseCount = parseInt('audioTrackReleaseCount');
    final nativeDestroyCallCount = parseInt('nativeDestroyCallCount');
    final seekAcceptedFrame = parseInt('seekAcceptedFrame', -1);
    final providerUnderrunEvents = parseInt('providerUnderrunEvents', -1);
    final providerFramesZeroFilled = parseInt('providerFramesZeroFilled', -1);
    final providerForwardSkipFrames = parseInt('providerForwardSkipFrames', -1);
    final providerRewindRejects = parseInt('providerRewindRejects', -1);
    final coordinatorSilenceCount = parseInt('coordinatorSilenceCount', -1);
    final cancellationPollCount = parseInt('cancellationPollCount');

    final lastError = parseString(
      'lastError',
      failureReason.isNotEmpty ? failureReason : (pass ? '' : status),
    );

    final finalLanes = <String, Object?>{
      'formatProbeOk': formatProbeOk,
      'audioTrackInitOk': audioTrackInitOk,
      'mutedOutputOk': mutedOutputOk,
      'nodeOwnedRouteDiscoveryOk': nodeOwnedRouteDiscoveryOk,
      'nodeOwnsRingOk': nodeOwnsRingOk,
      'startAckOk': startAckOk,
      'sinkClockedDispatchOk': sinkClockedDispatchOk,
      'timestampTelemetryOk': timestampTelemetryOk,
      'playbackHeadMonotonicOk': playbackHeadMonotonicOk,
      'playbackHeadAdvancedOk': playbackHeadAdvancedOk,
      'sinkWriteAccountingOk': sinkWriteAccountingOk,
      'checksumIdentityOk': checksumIdentityOk,
      'frameAccountingOk': frameAccountingOk,
      'seekOk': seekOk,
      'tailFlushOk': tailFlushOk,
      'steadyStateUnderrunFreeOk': steadyStateUnderrunFreeOk,
      'noProviderUnderrunOk': noProviderUnderrunOk,
      'noSilenceOk': noSilenceOk,
      'noForwardSkipOk': noForwardSkipOk,
      'noRewindRejectOk': noRewindRejectOk,
      'finalNotTerminalOk': finalNotTerminalOk,
      'finalSeekAckClearOk': finalSeekAckClearOk,
      'zeroNativeSteadyStateAllocationOk': zeroNativeSteadyStateAllocationOk,
      'cancellationPollingOk': cancellationPollingOk,
      'lifecycleOk': lifecycleOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{
      'sampleRate': sampleRate,
      'channelCount': channelCount,
      'pcmEncoding': pcmEncoding,
      'expectedFrameCount': expectedFrameCount,
      'totalFramesExtracted': totalFramesExtracted,
      'totalFramesAccepted': totalFramesAccepted,
      'totalOutputFramesDrained': totalOutputFramesDrained,
      'framesReadFromRingTotal': framesReadFromRingTotal,
      'framesWrittenTotal': framesWrittenTotal,
      'postSeekFramesAccepted': postSeekFramesAccepted,
      'postSeekFramesDrained': postSeekFramesDrained,
      'nativeAcceptedChecksumHex': nativeAcceptedChecksumHex,
      'nativeOutputDrainChecksumHex': nativeOutputDrainChecksumHex,
      'kotlinSinkChecksumHex': kotlinSinkChecksumHex,
      'dispatchCount': dispatchCount,
      'maxFramesPerMix': maxFramesPerMix,
      'sourceAvailableReadFrames': sourceAvailableReadFrames,
      'outputAvailableReadFrames': outputAvailableReadFrames,
      'nextDispatchFrame': nextDispatchFrame,
      'bootstrapDispatchCount': bootstrapDispatchCount,
      'sinkClockedDispatchCountEpoch0': sinkClockedDispatchCountEpoch0,
      'sinkClockedDispatchCountEpoch1': sinkClockedDispatchCountEpoch1,
      'prerollFrames': prerollFrames,
      'targetLeadFrames': targetLeadFrames,
      'bufferSizeInFrames': bufferSizeInFrames,
      'bufferCapacityInFrames': bufferCapacityInFrames,
      'startThresholdFrames': startThresholdFrames,
      'audioTimestampAttemptCount': audioTimestampAttemptCount,
      'audioTimestampSuccessCount': audioTimestampSuccessCount,
      'headSampleCount': headSampleCount,
      'playbackHeadFinal': playbackHeadFinal,
      'maxSinkLagFrames': maxSinkLagFrames,
      'maxDispatchLeadFrames': maxDispatchLeadFrames,
      'minDispatchLeadFrames': minDispatchLeadFrames,
      'underrunBaseline': underrunBaseline,
      'underrunFinal': underrunFinal,
      'underrunDelta': underrunDelta,
      'zeroWriteCount': zeroWriteCount,
      'partialWriteCount': partialWriteCount,
      'audioTrackReleaseCount': audioTrackReleaseCount,
      'nativeDestroyCallCount': nativeDestroyCallCount,
      'seekAcceptedFrame': seekAcceptedFrame,
      'providerUnderrunEvents': providerUnderrunEvents,
      'providerFramesZeroFilled': providerFramesZeroFilled,
      'providerForwardSkipFrames': providerForwardSkipFrames,
      'providerRewindRejects': providerRewindRejects,
      'coordinatorSilenceCount': coordinatorSilenceCount,
      'cancellationPollCount': cancellationPollCount,
      ...parsedMetrics,
    };

    return VGNodeOwnedSinkClockedTransportSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      details: details,
      formatProbeOk: formatProbeOk,
      audioTrackInitOk: audioTrackInitOk,
      mutedOutputOk: mutedOutputOk,
      nodeOwnedRouteDiscoveryOk: nodeOwnedRouteDiscoveryOk,
      nodeOwnsRingOk: nodeOwnsRingOk,
      startAckOk: startAckOk,
      sinkClockedDispatchOk: sinkClockedDispatchOk,
      timestampTelemetryOk: timestampTelemetryOk,
      playbackHeadMonotonicOk: playbackHeadMonotonicOk,
      playbackHeadAdvancedOk: playbackHeadAdvancedOk,
      sinkWriteAccountingOk: sinkWriteAccountingOk,
      checksumIdentityOk: checksumIdentityOk,
      frameAccountingOk: frameAccountingOk,
      seekOk: seekOk,
      tailFlushOk: tailFlushOk,
      steadyStateUnderrunFreeOk: steadyStateUnderrunFreeOk,
      noProviderUnderrunOk: noProviderUnderrunOk,
      noSilenceOk: noSilenceOk,
      noForwardSkipOk: noForwardSkipOk,
      noRewindRejectOk: noRewindRejectOk,
      finalNotTerminalOk: finalNotTerminalOk,
      finalSeekAckClearOk: finalSeekAckClearOk,
      zeroNativeSteadyStateAllocationOk: zeroNativeSteadyStateAllocationOk,
      cancellationPollingOk: cancellationPollingOk,
      lifecycleOk: lifecycleOk,
      canonical: canonical,
      sampleRate: sampleRate,
      channelCount: channelCount,
      pcmEncoding: pcmEncoding,
      expectedFrameCount: expectedFrameCount,
      totalFramesExtracted: totalFramesExtracted,
      totalFramesAccepted: totalFramesAccepted,
      totalOutputFramesDrained: totalOutputFramesDrained,
      framesReadFromRingTotal: framesReadFromRingTotal,
      framesWrittenTotal: framesWrittenTotal,
      postSeekFramesAccepted: postSeekFramesAccepted,
      postSeekFramesDrained: postSeekFramesDrained,
      nativeAcceptedChecksumHex: nativeAcceptedChecksumHex,
      nativeOutputDrainChecksumHex: nativeOutputDrainChecksumHex,
      kotlinSinkChecksumHex: kotlinSinkChecksumHex,
      dispatchCount: dispatchCount,
      maxFramesPerMix: maxFramesPerMix,
      sourceAvailableReadFrames: sourceAvailableReadFrames,
      outputAvailableReadFrames: outputAvailableReadFrames,
      nextDispatchFrame: nextDispatchFrame,
      bootstrapDispatchCount: bootstrapDispatchCount,
      sinkClockedDispatchCountEpoch0: sinkClockedDispatchCountEpoch0,
      sinkClockedDispatchCountEpoch1: sinkClockedDispatchCountEpoch1,
      prerollFrames: prerollFrames,
      targetLeadFrames: targetLeadFrames,
      bufferSizeInFrames: bufferSizeInFrames,
      bufferCapacityInFrames: bufferCapacityInFrames,
      startThresholdFrames: startThresholdFrames,
      audioTimestampAttemptCount: audioTimestampAttemptCount,
      audioTimestampSuccessCount: audioTimestampSuccessCount,
      headSampleCount: headSampleCount,
      playbackHeadFinal: playbackHeadFinal,
      maxSinkLagFrames: maxSinkLagFrames,
      maxDispatchLeadFrames: maxDispatchLeadFrames,
      minDispatchLeadFrames: minDispatchLeadFrames,
      underrunBaseline: underrunBaseline,
      underrunFinal: underrunFinal,
      underrunDelta: underrunDelta,
      zeroWriteCount: zeroWriteCount,
      partialWriteCount: partialWriteCount,
      audioTrackReleaseCount: audioTrackReleaseCount,
      nativeDestroyCallCount: nativeDestroyCallCount,
      seekAcceptedFrame: seekAcceptedFrame,
      providerUnderrunEvents: providerUnderrunEvents,
      providerFramesZeroFilled: providerFramesZeroFilled,
      providerForwardSkipFrames: providerForwardSkipFrames,
      providerRewindRejects: providerRewindRejects,
      coordinatorSilenceCount: coordinatorSilenceCount,
      cancellationPollCount: cancellationPollCount,
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

  static VGNodeOwnedSinkClockedTransportSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      'formatProbeOk': false,
      'audioTrackInitOk': false,
      'mutedOutputOk': false,
      'nodeOwnedRouteDiscoveryOk': false,
      'nodeOwnsRingOk': false,
      'startAckOk': false,
      'sinkClockedDispatchOk': false,
      'timestampTelemetryOk': false,
      'playbackHeadMonotonicOk': false,
      'playbackHeadAdvancedOk': false,
      'sinkWriteAccountingOk': false,
      'checksumIdentityOk': false,
      'frameAccountingOk': false,
      'seekOk': false,
      'tailFlushOk': false,
      'steadyStateUnderrunFreeOk': false,
      'noProviderUnderrunOk': false,
      'noSilenceOk': false,
      'noForwardSkipOk': false,
      'noRewindRejectOk': false,
      'finalNotTerminalOk': false,
      'finalSeekAckClearOk': false,
      'zeroNativeSteadyStateAllocationOk': false,
      'cancellationPollingOk': false,
      'lifecycleOk': false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'sampleRate': 0,
      'channelCount': 0,
      'pcmEncoding': 0,
      'expectedFrameCount': 0,
      'totalFramesExtracted': 0,
      'totalFramesAccepted': 0,
      'totalOutputFramesDrained': 0,
      'framesReadFromRingTotal': 0,
      'framesWrittenTotal': 0,
      'postSeekFramesAccepted': 0,
      'postSeekFramesDrained': 0,
      'nativeAcceptedChecksumHex': '',
      'nativeOutputDrainChecksumHex': '',
      'kotlinSinkChecksumHex': '',
      'dispatchCount': 0,
      'maxFramesPerMix': 0,
      'sourceAvailableReadFrames': -1,
      'outputAvailableReadFrames': -1,
      'nextDispatchFrame': -1,
      'bootstrapDispatchCount': 0,
      'sinkClockedDispatchCountEpoch0': 0,
      'sinkClockedDispatchCountEpoch1': 0,
      'prerollFrames': 0,
      'targetLeadFrames': 0,
      'bufferSizeInFrames': 0,
      'bufferCapacityInFrames': 0,
      'startThresholdFrames': -1,
      'audioTimestampAttemptCount': 0,
      'audioTimestampSuccessCount': 0,
      'headSampleCount': 0,
      'playbackHeadFinal': 0,
      'maxSinkLagFrames': -1,
      'maxDispatchLeadFrames': -1,
      'minDispatchLeadFrames': -1,
      'underrunBaseline': -1,
      'underrunFinal': -1,
      'underrunDelta': 0,
      'zeroWriteCount': 0,
      'partialWriteCount': 0,
      'audioTrackReleaseCount': 0,
      'nativeDestroyCallCount': 0,
      'seekAcceptedFrame': -1,
      'providerUnderrunEvents': -1,
      'providerFramesZeroFilled': -1,
      'providerForwardSkipFrames': -1,
      'providerRewindRejects': -1,
      'coordinatorSilenceCount': -1,
      'cancellationPollCount': 0,
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGNodeOwnedSinkClockedTransportSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      audioTrackInitOk: false,
      mutedOutputOk: false,
      nodeOwnedRouteDiscoveryOk: false,
      nodeOwnsRingOk: false,
      startAckOk: false,
      sinkClockedDispatchOk: false,
      timestampTelemetryOk: false,
      playbackHeadMonotonicOk: false,
      playbackHeadAdvancedOk: false,
      sinkWriteAccountingOk: false,
      checksumIdentityOk: false,
      frameAccountingOk: false,
      seekOk: false,
      tailFlushOk: false,
      steadyStateUnderrunFreeOk: false,
      noProviderUnderrunOk: false,
      noSilenceOk: false,
      noForwardSkipOk: false,
      noRewindRejectOk: false,
      finalNotTerminalOk: false,
      finalSeekAckClearOk: false,
      zeroNativeSteadyStateAllocationOk: false,
      cancellationPollingOk: false,
      lifecycleOk: false,
      canonical: false,
      sampleRate: 0,
      channelCount: 0,
      pcmEncoding: 0,
      expectedFrameCount: 0,
      totalFramesExtracted: 0,
      totalFramesAccepted: 0,
      totalOutputFramesDrained: 0,
      framesReadFromRingTotal: 0,
      framesWrittenTotal: 0,
      postSeekFramesAccepted: 0,
      postSeekFramesDrained: 0,
      nativeAcceptedChecksumHex: '',
      nativeOutputDrainChecksumHex: '',
      kotlinSinkChecksumHex: '',
      dispatchCount: 0,
      maxFramesPerMix: 0,
      sourceAvailableReadFrames: -1,
      outputAvailableReadFrames: -1,
      nextDispatchFrame: -1,
      bootstrapDispatchCount: 0,
      sinkClockedDispatchCountEpoch0: 0,
      sinkClockedDispatchCountEpoch1: 0,
      prerollFrames: 0,
      targetLeadFrames: 0,
      bufferSizeInFrames: 0,
      bufferCapacityInFrames: 0,
      startThresholdFrames: -1,
      audioTimestampAttemptCount: 0,
      audioTimestampSuccessCount: 0,
      headSampleCount: 0,
      playbackHeadFinal: 0,
      maxSinkLagFrames: -1,
      maxDispatchLeadFrames: -1,
      minDispatchLeadFrames: -1,
      underrunBaseline: -1,
      underrunFinal: -1,
      underrunDelta: 0,
      zeroWriteCount: 0,
      partialWriteCount: 0,
      audioTrackReleaseCount: 0,
      nativeDestroyCallCount: 0,
      seekAcceptedFrame: -1,
      providerUnderrunEvents: -1,
      providerFramesZeroFilled: -1,
      providerForwardSkipFrames: -1,
      providerRewindRejects: -1,
      coordinatorSilenceCount: -1,
      cancellationPollCount: 0,
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      raw: Map<String, String>.unmodifiable(<String, String>{
        'status': 'FAIL',
        'reason': reason,
      }),
      lastError: lastError,
    );
  }

  /// Invokes the Android True-DAG Phase 4 node-owned AudioTrack sink-clocked
  /// transport diagnostic proof smoke harness.
  ///
  /// [sourcePath] path to the source audio/video media file (required).
  /// [durationSec] duration in seconds to process (default 1.0, max 2.0).
  /// [seekTargetSec] seek target position in seconds (default 0.35).
  /// [sourceRingCapacityFrames] capacity of source ring in frames (default 8192).
  /// [outputRingCapacityFrames] capacity of output ring in frames (default 4096).
  /// [maxFramesPerMix] max frames per mix dispatch cycle (default 256).
  /// [timeout] optionally bounds the invocation; deadlineMs is passed to Kotlin.
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGNodeOwnedSinkClockedTransportSmokeReport>
  runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke({
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
      return VGNodeOwnedSinkClockedTransportSmokeReport.fromMap(raw);
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
    return other is VGNodeOwnedSinkClockedTransportSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.formatProbeOk == formatProbeOk &&
        other.audioTrackInitOk == audioTrackInitOk &&
        other.mutedOutputOk == mutedOutputOk &&
        other.nodeOwnedRouteDiscoveryOk == nodeOwnedRouteDiscoveryOk &&
        other.nodeOwnsRingOk == nodeOwnsRingOk &&
        other.startAckOk == startAckOk &&
        other.sinkClockedDispatchOk == sinkClockedDispatchOk &&
        other.timestampTelemetryOk == timestampTelemetryOk &&
        other.playbackHeadMonotonicOk == playbackHeadMonotonicOk &&
        other.playbackHeadAdvancedOk == playbackHeadAdvancedOk &&
        other.sinkWriteAccountingOk == sinkWriteAccountingOk &&
        other.checksumIdentityOk == checksumIdentityOk &&
        other.frameAccountingOk == frameAccountingOk &&
        other.seekOk == seekOk &&
        other.tailFlushOk == tailFlushOk &&
        other.steadyStateUnderrunFreeOk == steadyStateUnderrunFreeOk &&
        other.noProviderUnderrunOk == noProviderUnderrunOk &&
        other.noSilenceOk == noSilenceOk &&
        other.noForwardSkipOk == noForwardSkipOk &&
        other.noRewindRejectOk == noRewindRejectOk &&
        other.finalNotTerminalOk == finalNotTerminalOk &&
        other.finalSeekAckClearOk == finalSeekAckClearOk &&
        other.zeroNativeSteadyStateAllocationOk ==
            zeroNativeSteadyStateAllocationOk &&
        other.cancellationPollingOk == cancellationPollingOk &&
        other.lifecycleOk == lifecycleOk &&
        other.canonical == canonical &&
        other.sampleRate == sampleRate &&
        other.channelCount == channelCount &&
        other.pcmEncoding == pcmEncoding &&
        other.expectedFrameCount == expectedFrameCount &&
        other.totalFramesExtracted == totalFramesExtracted &&
        other.totalFramesAccepted == totalFramesAccepted &&
        other.totalOutputFramesDrained == totalOutputFramesDrained &&
        other.framesReadFromRingTotal == framesReadFromRingTotal &&
        other.framesWrittenTotal == framesWrittenTotal &&
        other.postSeekFramesAccepted == postSeekFramesAccepted &&
        other.postSeekFramesDrained == postSeekFramesDrained &&
        other.nativeAcceptedChecksumHex == nativeAcceptedChecksumHex &&
        other.nativeOutputDrainChecksumHex == nativeOutputDrainChecksumHex &&
        other.kotlinSinkChecksumHex == kotlinSinkChecksumHex &&
        other.dispatchCount == dispatchCount &&
        other.maxFramesPerMix == maxFramesPerMix &&
        other.sourceAvailableReadFrames == sourceAvailableReadFrames &&
        other.outputAvailableReadFrames == outputAvailableReadFrames &&
        other.nextDispatchFrame == nextDispatchFrame &&
        other.bootstrapDispatchCount == bootstrapDispatchCount &&
        other.sinkClockedDispatchCountEpoch0 ==
            sinkClockedDispatchCountEpoch0 &&
        other.sinkClockedDispatchCountEpoch1 ==
            sinkClockedDispatchCountEpoch1 &&
        other.prerollFrames == prerollFrames &&
        other.targetLeadFrames == targetLeadFrames &&
        other.bufferSizeInFrames == bufferSizeInFrames &&
        other.bufferCapacityInFrames == bufferCapacityInFrames &&
        other.startThresholdFrames == startThresholdFrames &&
        other.audioTimestampAttemptCount == audioTimestampAttemptCount &&
        other.audioTimestampSuccessCount == audioTimestampSuccessCount &&
        other.headSampleCount == headSampleCount &&
        other.playbackHeadFinal == playbackHeadFinal &&
        other.maxSinkLagFrames == maxSinkLagFrames &&
        other.maxDispatchLeadFrames == maxDispatchLeadFrames &&
        other.minDispatchLeadFrames == minDispatchLeadFrames &&
        other.underrunBaseline == underrunBaseline &&
        other.underrunFinal == underrunFinal &&
        other.underrunDelta == underrunDelta &&
        other.zeroWriteCount == zeroWriteCount &&
        other.partialWriteCount == partialWriteCount &&
        other.audioTrackReleaseCount == audioTrackReleaseCount &&
        other.nativeDestroyCallCount == nativeDestroyCallCount &&
        other.seekAcceptedFrame == seekAcceptedFrame &&
        other.providerUnderrunEvents == providerUnderrunEvents &&
        other.providerFramesZeroFilled == providerFramesZeroFilled &&
        other.providerForwardSkipFrames == providerForwardSkipFrames &&
        other.providerRewindRejects == providerRewindRejects &&
        other.coordinatorSilenceCount == coordinatorSilenceCount &&
        other.cancellationPollCount == cancellationPollCount &&
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
    audioTrackInitOk,
    mutedOutputOk,
    nodeOwnedRouteDiscoveryOk,
    nodeOwnsRingOk,
    startAckOk,
    sinkClockedDispatchOk,
    timestampTelemetryOk,
    playbackHeadMonotonicOk,
    playbackHeadAdvancedOk,
    sinkWriteAccountingOk,
    checksumIdentityOk,
    frameAccountingOk,
    seekOk,
    tailFlushOk,
    steadyStateUnderrunFreeOk,
    noProviderUnderrunOk,
    noSilenceOk,
    noForwardSkipOk,
    noRewindRejectOk,
    finalNotTerminalOk,
    finalSeekAckClearOk,
    zeroNativeSteadyStateAllocationOk,
    cancellationPollingOk,
    lifecycleOk,
    canonical,
    sampleRate,
    channelCount,
    pcmEncoding,
    expectedFrameCount,
    totalFramesExtracted,
    totalFramesAccepted,
    totalOutputFramesDrained,
    framesReadFromRingTotal,
    framesWrittenTotal,
    postSeekFramesAccepted,
    postSeekFramesDrained,
    nativeAcceptedChecksumHex,
    nativeOutputDrainChecksumHex,
    kotlinSinkChecksumHex,
    dispatchCount,
    maxFramesPerMix,
    sourceAvailableReadFrames,
    outputAvailableReadFrames,
    nextDispatchFrame,
    bootstrapDispatchCount,
    sinkClockedDispatchCountEpoch0,
    sinkClockedDispatchCountEpoch1,
    prerollFrames,
    targetLeadFrames,
    bufferSizeInFrames,
    bufferCapacityInFrames,
    startThresholdFrames,
    audioTimestampAttemptCount,
    audioTimestampSuccessCount,
    headSampleCount,
    playbackHeadFinal,
    maxSinkLagFrames,
    maxDispatchLeadFrames,
    minDispatchLeadFrames,
    underrunBaseline,
    underrunFinal,
    underrunDelta,
    zeroWriteCount,
    partialWriteCount,
    audioTrackReleaseCount,
    nativeDestroyCallCount,
    seekAcceptedFrame,
    providerUnderrunEvents,
    providerFramesZeroFilled,
    providerForwardSkipFrames,
    providerRewindRejects,
    coordinatorSilenceCount,
    cancellationPollCount,
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
      'VGNodeOwnedSinkClockedTransportSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'failureReason: $failureReason, '
      'details: $details, '
      'formatProbeOk: $formatProbeOk, '
      'audioTrackInitOk: $audioTrackInitOk, '
      'mutedOutputOk: $mutedOutputOk, '
      'nodeOwnedRouteDiscoveryOk: $nodeOwnedRouteDiscoveryOk, '
      'nodeOwnsRingOk: $nodeOwnsRingOk, '
      'startAckOk: $startAckOk, '
      'sinkClockedDispatchOk: $sinkClockedDispatchOk, '
      'timestampTelemetryOk: $timestampTelemetryOk, '
      'playbackHeadMonotonicOk: $playbackHeadMonotonicOk, '
      'playbackHeadAdvancedOk: $playbackHeadAdvancedOk, '
      'sinkWriteAccountingOk: $sinkWriteAccountingOk, '
      'checksumIdentityOk: $checksumIdentityOk, '
      'frameAccountingOk: $frameAccountingOk, '
      'seekOk: $seekOk, '
      'tailFlushOk: $tailFlushOk, '
      'steadyStateUnderrunFreeOk: $steadyStateUnderrunFreeOk, '
      'noProviderUnderrunOk: $noProviderUnderrunOk, '
      'noSilenceOk: $noSilenceOk, '
      'noForwardSkipOk: $noForwardSkipOk, '
      'noRewindRejectOk: $noRewindRejectOk, '
      'finalNotTerminalOk: $finalNotTerminalOk, '
      'finalSeekAckClearOk: $finalSeekAckClearOk, '
      'zeroNativeSteadyStateAllocationOk: $zeroNativeSteadyStateAllocationOk, '
      'cancellationPollingOk: $cancellationPollingOk, '
      'lifecycleOk: $lifecycleOk, '
      'canonical: $canonical, '
      'sampleRate: $sampleRate, '
      'channelCount: $channelCount, '
      'pcmEncoding: $pcmEncoding, '
      'expectedFrameCount: $expectedFrameCount, '
      'totalFramesExtracted: $totalFramesExtracted, '
      'totalFramesAccepted: $totalFramesAccepted, '
      'totalOutputFramesDrained: $totalOutputFramesDrained, '
      'framesReadFromRingTotal: $framesReadFromRingTotal, '
      'framesWrittenTotal: $framesWrittenTotal, '
      'postSeekFramesAccepted: $postSeekFramesAccepted, '
      'postSeekFramesDrained: $postSeekFramesDrained, '
      'nativeAcceptedChecksumHex: $nativeAcceptedChecksumHex, '
      'nativeOutputDrainChecksumHex: $nativeOutputDrainChecksumHex, '
      'kotlinSinkChecksumHex: $kotlinSinkChecksumHex, '
      'dispatchCount: $dispatchCount, '
      'maxFramesPerMix: $maxFramesPerMix, '
      'sourceAvailableReadFrames: $sourceAvailableReadFrames, '
      'outputAvailableReadFrames: $outputAvailableReadFrames, '
      'nextDispatchFrame: $nextDispatchFrame, '
      'bootstrapDispatchCount: $bootstrapDispatchCount, '
      'sinkClockedDispatchCountEpoch0: $sinkClockedDispatchCountEpoch0, '
      'sinkClockedDispatchCountEpoch1: $sinkClockedDispatchCountEpoch1, '
      'prerollFrames: $prerollFrames, '
      'targetLeadFrames: $targetLeadFrames, '
      'bufferSizeInFrames: $bufferSizeInFrames, '
      'bufferCapacityInFrames: $bufferCapacityInFrames, '
      'startThresholdFrames: $startThresholdFrames, '
      'audioTimestampAttemptCount: $audioTimestampAttemptCount, '
      'audioTimestampSuccessCount: $audioTimestampSuccessCount, '
      'headSampleCount: $headSampleCount, '
      'playbackHeadFinal: $playbackHeadFinal, '
      'maxSinkLagFrames: $maxSinkLagFrames, '
      'maxDispatchLeadFrames: $maxDispatchLeadFrames, '
      'minDispatchLeadFrames: $minDispatchLeadFrames, '
      'underrunBaseline: $underrunBaseline, '
      'underrunFinal: $underrunFinal, '
      'underrunDelta: $underrunDelta, '
      'zeroWriteCount: $zeroWriteCount, '
      'partialWriteCount: $partialWriteCount, '
      'audioTrackReleaseCount: $audioTrackReleaseCount, '
      'nativeDestroyCallCount: $nativeDestroyCallCount, '
      'seekAcceptedFrame: $seekAcceptedFrame, '
      'providerUnderrunEvents: $providerUnderrunEvents, '
      'providerFramesZeroFilled: $providerFramesZeroFilled, '
      'providerForwardSkipFrames: $providerForwardSkipFrames, '
      'providerRewindRejects: $providerRewindRejects, '
      'coordinatorSilenceCount: $coordinatorSilenceCount, '
      'cancellationPollCount: $cancellationPollCount, '
      'lanes: $lanes, '
      'metrics: $metrics, '
      'raw: $raw, '
      'lastError: $lastError)';
}
