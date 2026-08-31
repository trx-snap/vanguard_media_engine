// vg_real_decoder_pipeline_smoke.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice H2: Android True-DAG Phase 4
// real MediaExtractor/MediaCodec decoder closed-loop native audio graph pipeline diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4RealDecoderPipelineSmoke` MethodChannel route.
// Diagnostic-only - validates the real MediaExtractor/MediaCodec streaming decode
// driving the session-scoped, step-driven closed-loop native audio graph pipeline:
// MediaExtractor/MediaCodec -> direct ByteBuffer PCM16 -> AudioDecoderRingWriter ->
// source AudioSpscAudioRingBuffer -> RingBufferAudioSampleProvider ->
// GraphAudioScheduler -> AudioMixBusNode -> ClockedAudioTransportCoordinator ->
// output AudioSpscAudioRingBuffer -> consumer drain.
// Single routed track at unit gain with caller-derived clock ticks.
//
// Honest non-claims (Proof Boundary):
// kotlin_owned_real_decoder_step_driven_closed_loop_native_audio_graph_pipeline_session_proof_only_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_native_frame_axis_is_accepted_frame_count_not_media_pts_seek_reanchors_at_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_pre_seek_writer_eos_tail_flush_then_seek_clears_eos_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_diagnostic_graph_topology_only_no_production_source_node_wiring_no_source_node_pcm_ingest_topology_anchor_only_single_routed_track_unit_gain_only_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealDecoderPipelineSmokeReport.runAndroidDagPhase4RealDecoderPipelineSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGRealDecoderPipelineSmokeReport {
  const VGRealDecoderPipelineSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.decoderBenignFormatChangeObserved,
    required this.decoderEosReachedOk,
    required this.sourcePartialWriteObserved,
    required this.sourceRingFullObserved,
    required this.outputBackpressureObserved,
    required this.checksumIdentityOk,
    required this.frameAccountingOk,
    required this.seekOk,
    required this.tailFlushOk,
    required this.noUnderrunOk,
    required this.noSilenceOk,
    required this.noRingPushShortfallOk,
    required this.noForwardSkipOk,
    required this.noRewindRejectOk,
    required this.finalNotTerminalOk,
    required this.finalSeekAckClearOk,
    required this.zeroNativeSteadyStateAllocationOk,
    required this.ownerThreadOk,
    required this.lifecycleOk,
    required this.canonical,
    required this.sampleRate,
    required this.channelCount,
    required this.pcmEncoding,
    required this.totalFramesExtracted,
    required this.totalFramesAccepted,
    required this.totalOutputFramesDrained,
    required this.postSeekFramesAccepted,
    required this.postSeekFramesDrained,
    required this.decoderBenignFormatChangeCount,
    required this.providerUnderrunEvents,
    required this.providerFramesZeroFilled,
    required this.providerForwardSkipFrames,
    required this.providerRewindRejects,
    required this.coordinatorSilenceCount,
    required this.nativeAcceptedChecksumHex,
    required this.nativeOutputDrainChecksumHex,
    required this.kotlinAcceptedChecksumHex,
    required this.maxFramesPerMix,
    required this.sourceAvailableReadFrames,
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
      'runAndroidDagPhase4RealDecoderPipelineSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REAL_DECODER_PIPELINE_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REAL_DECODER_PIPELINE_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'kotlin_owned_real_decoder_step_driven_closed_loop_native_audio_graph_pipeline_session_proof_only_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_native_frame_axis_is_accepted_frame_count_not_media_pts_seek_reanchors_at_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_pre_seek_writer_eos_tail_flush_then_seek_clears_eos_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_diagnostic_graph_topology_only_no_production_source_node_wiring_no_source_node_pcm_ingest_topology_anchor_only_single_routed_track_unit_gain_only_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim';

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

  // ---- Lanes --------------------------------------------------------------

  /// Whether initial audio format probe succeeded (PCM16, 1..2 channels).
  final bool formatProbeOk;

  /// Whether benign repeat format changes were observed without error.
  final bool decoderBenignFormatChangeObserved;

  /// Whether decoder EOS was reached and tail flush completed cleanly.
  final bool decoderEosReachedOk;

  /// Whether partial ring write backpressure was observed on the source ring.
  final bool sourcePartialWriteObserved;

  /// Whether ring full condition was observed on the source ring.
  final bool sourceRingFullObserved;

  /// Whether output ring backpressure condition was observed.
  final bool outputBackpressureObserved;

  /// Whether 3-way checksum identity holds (Kotlin == native accepted == native drained).
  final bool checksumIdentityOk;

  /// Whether total frames accepted equals total frames drained.
  final bool frameAccountingOk;

  /// Whether seek boundary re-based cursor with zero discards.
  final bool seekOk;

  /// Whether tail flush steps advanced partial window and completed cleanly.
  final bool tailFlushOk;

  /// Whether no provider underruns occurred.
  final bool noUnderrunOk;

  /// Whether no coordinator silence windows occurred.
  final bool noSilenceOk;

  /// Whether no ring push shortfall or terminal errors occurred.
  final bool noRingPushShortfallOk;

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

  /// Whether foreign thread operations were rejected with wrong_owner_thread.
  final bool ownerThreadOk;

  /// Whether session lifecycle creation, rejection, and destroy were idempotent.
  final bool lifecycleOk;

  /// Canonical pass indicator.
  final bool canonical;

  // ---- Metrics ------------------------------------------------------------

  /// Resolved sampling rate in Hz.
  final int sampleRate;

  /// Resolved channel count (1 or 2).
  final int channelCount;

  /// Resolved PCM encoding (AudioFormat.ENCODING_PCM_16BIT = 2).
  final int pcmEncoding;

  /// Total frames extracted from MediaExtractor.
  final int totalFramesExtracted;

  /// Total frames accepted into the pipeline.
  final int totalFramesAccepted;

  /// Total frames drained from the output ring.
  final int totalOutputFramesDrained;

  /// Total frames accepted after the forward seek boundary.
  final int postSeekFramesAccepted;

  /// Total frames drained after the forward seek boundary.
  final int postSeekFramesDrained;

  /// Count of benign repeated format change events observed.
  final int decoderBenignFormatChangeCount;

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

  /// 64-bit hexadecimal checksum computed on the native accepted side.
  final String nativeAcceptedChecksumHex;

  /// 64-bit hexadecimal checksum computed on the native output drain side.
  final String nativeOutputDrainChecksumHex;

  /// 64-bit hexadecimal checksum computed on the Kotlin accepted side.
  final String kotlinAcceptedChecksumHex;

  /// Maximum frames rendered per mix dispatch cycle.
  final int maxFramesPerMix;

  /// Source ring available read frames at last snapshot.
  final int sourceAvailableReadFrames;

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

  /// Whether Kotlin accepted, native accepted, and native output drain checksums
  /// match, are non-empty, and [checksumIdentityOk] holds.
  bool get checksumsMatch =>
      kotlinAcceptedChecksumHex.isNotEmpty &&
      kotlinAcceptedChecksumHex == nativeAcceptedChecksumHex &&
      nativeAcceptedChecksumHex == nativeOutputDrainChecksumHex &&
      checksumIdentityOk;

  /// Whether all native diagnostic lanes passed according to the H2 verification contract.
  ///
  /// Note: [decoderBenignFormatChangeObserved] is benign telemetry and is NOT
  /// required to be true for overall pass.
  bool get allNativeLanesPass =>
      pass &&
      hasCanonicalProofBoundary &&
      status.toLowerCase() == 'pass' &&
      marker == passMarkerConstant &&
      formatProbeOk &&
      decoderEosReachedOk &&
      sourcePartialWriteObserved &&
      sourceRingFullObserved &&
      outputBackpressureObserved &&
      checksumIdentityOk &&
      frameAccountingOk &&
      seekOk &&
      tailFlushOk &&
      noUnderrunOk &&
      noSilenceOk &&
      noRingPushShortfallOk &&
      noForwardSkipOk &&
      noRewindRejectOk &&
      finalNotTerminalOk &&
      finalSeekAckClearOk &&
      zeroNativeSteadyStateAllocationOk &&
      ownerThreadOk &&
      lifecycleOk &&
      canonical &&
      sampleRate > 0 &&
      channelCount > 0 &&
      totalFramesAccepted > 0 &&
      totalOutputFramesDrained > 0 &&
      postSeekFramesAccepted > 0 &&
      postSeekFramesDrained > 0 &&
      dispatchCount > 0 &&
      maxFramesPerMix > 0 &&
      providerUnderrunEvents == 0 &&
      providerFramesZeroFilled == 0 &&
      providerForwardSkipFrames == 0 &&
      providerRewindRejects == 0 &&
      coordinatorSilenceCount == 0 &&
      checksumsMatch &&
      (lastError.isEmpty || lastError == 'none' || lastError == 'null');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealDecoderPipelineSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGRealDecoderPipelineSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        formatProbeOk: false,
        decoderBenignFormatChangeObserved: false,
        decoderEosReachedOk: false,
        sourcePartialWriteObserved: false,
        sourceRingFullObserved: false,
        outputBackpressureObserved: false,
        checksumIdentityOk: false,
        frameAccountingOk: false,
        seekOk: false,
        tailFlushOk: false,
        noUnderrunOk: false,
        noSilenceOk: false,
        noRingPushShortfallOk: false,
        noForwardSkipOk: false,
        noRewindRejectOk: false,
        finalNotTerminalOk: false,
        finalSeekAckClearOk: false,
        zeroNativeSteadyStateAllocationOk: false,
        ownerThreadOk: false,
        lifecycleOk: false,
        canonical: false,
        sampleRate: 0,
        channelCount: 0,
        pcmEncoding: 0,
        totalFramesExtracted: 0,
        totalFramesAccepted: 0,
        totalOutputFramesDrained: 0,
        postSeekFramesAccepted: 0,
        postSeekFramesDrained: 0,
        decoderBenignFormatChangeCount: 0,
        providerUnderrunEvents: 0,
        providerFramesZeroFilled: 0,
        providerForwardSkipFrames: 0,
        providerRewindRejects: 0,
        coordinatorSilenceCount: 0,
        nativeAcceptedChecksumHex: '',
        nativeOutputDrainChecksumHex: '',
        kotlinAcceptedChecksumHex: '',
        maxFramesPerMix: 0,
        sourceAvailableReadFrames: -1,
        outputAvailableReadFrames: -1,
        dispatchCount: 0,
        nextDispatchFrame: -1,
        nativeLastStatus: '',
        lanes: <String, Object?>{
          'formatProbeOk': false,
          'decoderBenignFormatChangeObserved': false,
          'decoderEosReachedOk': false,
          'sourcePartialWriteObserved': false,
          'sourceRingFullObserved': false,
          'outputBackpressureObserved': false,
          'checksumIdentityOk': false,
          'frameAccountingOk': false,
          'seekOk': false,
          'tailFlushOk': false,
          'noUnderrunOk': false,
          'noSilenceOk': false,
          'noRingPushShortfallOk': false,
          'noForwardSkipOk': false,
          'noRewindRejectOk': false,
          'finalNotTerminalOk': false,
          'finalSeekAckClearOk': false,
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
    final decoderBenignFormatChangeObserved = parseBool(
      'decoderBenignFormatChangeObserved',
    );
    final decoderEosReachedOk = parseBool('decoderEosReachedOk');
    final sourcePartialWriteObserved = parseBool('sourcePartialWriteObserved');
    final sourceRingFullObserved = parseBool('sourceRingFullObserved');
    final outputBackpressureObserved = parseBool('outputBackpressureObserved');
    final checksumIdentityOk = parseBool('checksumIdentityOk');
    final frameAccountingOk = parseBool('frameAccountingOk');
    final seekOk = parseBool('seekOk');
    final tailFlushOk = parseBool('tailFlushOk');
    final noUnderrunOk = parseBool('noUnderrunOk');
    final noSilenceOk = parseBool('noSilenceOk');
    final noRingPushShortfallOk = parseBool('noRingPushShortfallOk');
    final noForwardSkipOk = parseBool('noForwardSkipOk');
    final noRewindRejectOk = parseBool('noRewindRejectOk');
    final finalNotTerminalOk = parseBool('finalNotTerminalOk');
    final finalSeekAckClearOk = parseBool('finalSeekAckClearOk');
    final zeroNativeSteadyStateAllocationOk = parseBool(
      'zeroNativeSteadyStateAllocationOk',
    );
    final ownerThreadOk = parseBool('ownerThreadOk');
    final lifecycleOk = parseBool('lifecycleOk');
    final canonical = parseBool('canonical', pass);

    final sampleRate = parseInt('sampleRate');
    final channelCount = parseInt('channelCount');
    final pcmEncoding = parseInt('pcmEncoding');
    final totalFramesExtracted = parseInt('totalFramesExtracted');
    final totalFramesAccepted = parseInt('totalFramesAccepted');
    final totalOutputFramesDrained = parseInt('totalOutputFramesDrained');
    final postSeekFramesAccepted = parseInt('postSeekFramesAccepted');
    final postSeekFramesDrained = parseInt('postSeekFramesDrained');
    final decoderBenignFormatChangeCount = parseInt(
      'decoderBenignFormatChangeCount',
    );
    final providerUnderrunEvents = parseInt('providerUnderrunEvents');
    final providerFramesZeroFilled = parseInt('providerFramesZeroFilled');
    final providerForwardSkipFrames = parseInt('providerForwardSkipFrames');
    final providerRewindRejects = parseInt('providerRewindRejects');
    final coordinatorSilenceCount = parseInt('coordinatorSilenceCount');
    final nativeAcceptedChecksumHex = parseString('nativeAcceptedChecksumHex');
    final nativeOutputDrainChecksumHex = parseString(
      'nativeOutputDrainChecksumHex',
    );
    final kotlinAcceptedChecksumHex = parseString('kotlinAcceptedChecksumHex');
    final maxFramesPerMix = parseInt('maxFramesPerMix');
    final sourceAvailableReadFrames = parseInt('sourceAvailableReadFrames', -1);
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
      'decoderBenignFormatChangeObserved': decoderBenignFormatChangeObserved,
      'decoderEosReachedOk': decoderEosReachedOk,
      'sourcePartialWriteObserved': sourcePartialWriteObserved,
      'sourceRingFullObserved': sourceRingFullObserved,
      'outputBackpressureObserved': outputBackpressureObserved,
      'checksumIdentityOk': checksumIdentityOk,
      'frameAccountingOk': frameAccountingOk,
      'seekOk': seekOk,
      'tailFlushOk': tailFlushOk,
      'noUnderrunOk': noUnderrunOk,
      'noSilenceOk': noSilenceOk,
      'noRingPushShortfallOk': noRingPushShortfallOk,
      'noForwardSkipOk': noForwardSkipOk,
      'noRewindRejectOk': noRewindRejectOk,
      'finalNotTerminalOk': finalNotTerminalOk,
      'finalSeekAckClearOk': finalSeekAckClearOk,
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
      'totalFramesExtracted': totalFramesExtracted,
      'totalFramesAccepted': totalFramesAccepted,
      'totalOutputFramesDrained': totalOutputFramesDrained,
      'postSeekFramesAccepted': postSeekFramesAccepted,
      'postSeekFramesDrained': postSeekFramesDrained,
      'decoderBenignFormatChangeCount': decoderBenignFormatChangeCount,
      'providerUnderrunEvents': providerUnderrunEvents,
      'providerFramesZeroFilled': providerFramesZeroFilled,
      'providerForwardSkipFrames': providerForwardSkipFrames,
      'providerRewindRejects': providerRewindRejects,
      'coordinatorSilenceCount': coordinatorSilenceCount,
      'nativeAcceptedChecksumHex': nativeAcceptedChecksumHex,
      'nativeOutputDrainChecksumHex': nativeOutputDrainChecksumHex,
      'kotlinAcceptedChecksumHex': kotlinAcceptedChecksumHex,
      'maxFramesPerMix': maxFramesPerMix,
      'sourceAvailableReadFrames': sourceAvailableReadFrames,
      'outputAvailableReadFrames': outputAvailableReadFrames,
      'dispatchCount': dispatchCount,
      'nextDispatchFrame': nextDispatchFrame,
      'nativeLastStatus': nativeLastStatus,
      ...parsedMetrics,
    };

    return VGRealDecoderPipelineSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      details: details,
      formatProbeOk: formatProbeOk,
      decoderBenignFormatChangeObserved: decoderBenignFormatChangeObserved,
      decoderEosReachedOk: decoderEosReachedOk,
      sourcePartialWriteObserved: sourcePartialWriteObserved,
      sourceRingFullObserved: sourceRingFullObserved,
      outputBackpressureObserved: outputBackpressureObserved,
      checksumIdentityOk: checksumIdentityOk,
      frameAccountingOk: frameAccountingOk,
      seekOk: seekOk,
      tailFlushOk: tailFlushOk,
      noUnderrunOk: noUnderrunOk,
      noSilenceOk: noSilenceOk,
      noRingPushShortfallOk: noRingPushShortfallOk,
      noForwardSkipOk: noForwardSkipOk,
      noRewindRejectOk: noRewindRejectOk,
      finalNotTerminalOk: finalNotTerminalOk,
      finalSeekAckClearOk: finalSeekAckClearOk,
      zeroNativeSteadyStateAllocationOk: zeroNativeSteadyStateAllocationOk,
      ownerThreadOk: ownerThreadOk,
      lifecycleOk: lifecycleOk,
      canonical: canonical,
      sampleRate: sampleRate,
      channelCount: channelCount,
      pcmEncoding: pcmEncoding,
      totalFramesExtracted: totalFramesExtracted,
      totalFramesAccepted: totalFramesAccepted,
      totalOutputFramesDrained: totalOutputFramesDrained,
      postSeekFramesAccepted: postSeekFramesAccepted,
      postSeekFramesDrained: postSeekFramesDrained,
      decoderBenignFormatChangeCount: decoderBenignFormatChangeCount,
      providerUnderrunEvents: providerUnderrunEvents,
      providerFramesZeroFilled: providerFramesZeroFilled,
      providerForwardSkipFrames: providerForwardSkipFrames,
      providerRewindRejects: providerRewindRejects,
      coordinatorSilenceCount: coordinatorSilenceCount,
      nativeAcceptedChecksumHex: nativeAcceptedChecksumHex,
      nativeOutputDrainChecksumHex: nativeOutputDrainChecksumHex,
      kotlinAcceptedChecksumHex: kotlinAcceptedChecksumHex,
      maxFramesPerMix: maxFramesPerMix,
      sourceAvailableReadFrames: sourceAvailableReadFrames,
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

  static VGRealDecoderPipelineSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      'formatProbeOk': false,
      'decoderBenignFormatChangeObserved': false,
      'decoderEosReachedOk': false,
      'sourcePartialWriteObserved': false,
      'sourceRingFullObserved': false,
      'outputBackpressureObserved': false,
      'checksumIdentityOk': false,
      'frameAccountingOk': false,
      'seekOk': false,
      'tailFlushOk': false,
      'noUnderrunOk': false,
      'noSilenceOk': false,
      'noRingPushShortfallOk': false,
      'noForwardSkipOk': false,
      'noRewindRejectOk': false,
      'finalNotTerminalOk': false,
      'finalSeekAckClearOk': false,
      'zeroNativeSteadyStateAllocationOk': false,
      'ownerThreadOk': false,
      'lifecycleOk': false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'sampleRate': 0,
      'channelCount': 0,
      'pcmEncoding': 0,
      'totalFramesExtracted': 0,
      'totalFramesAccepted': 0,
      'totalOutputFramesDrained': 0,
      'postSeekFramesAccepted': 0,
      'postSeekFramesDrained': 0,
      'decoderBenignFormatChangeCount': 0,
      'providerUnderrunEvents': 0,
      'providerFramesZeroFilled': 0,
      'providerForwardSkipFrames': 0,
      'providerRewindRejects': 0,
      'coordinatorSilenceCount': 0,
      'nativeAcceptedChecksumHex': '',
      'nativeOutputDrainChecksumHex': '',
      'kotlinAcceptedChecksumHex': '',
      'maxFramesPerMix': 0,
      'sourceAvailableReadFrames': -1,
      'outputAvailableReadFrames': -1,
      'dispatchCount': 0,
      'nextDispatchFrame': -1,
      'nativeLastStatus': '',
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGRealDecoderPipelineSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      decoderBenignFormatChangeObserved: false,
      decoderEosReachedOk: false,
      sourcePartialWriteObserved: false,
      sourceRingFullObserved: false,
      outputBackpressureObserved: false,
      checksumIdentityOk: false,
      frameAccountingOk: false,
      seekOk: false,
      tailFlushOk: false,
      noUnderrunOk: false,
      noSilenceOk: false,
      noRingPushShortfallOk: false,
      noForwardSkipOk: false,
      noRewindRejectOk: false,
      finalNotTerminalOk: false,
      finalSeekAckClearOk: false,
      zeroNativeSteadyStateAllocationOk: false,
      ownerThreadOk: false,
      lifecycleOk: false,
      canonical: false,
      sampleRate: 0,
      channelCount: 0,
      pcmEncoding: 0,
      totalFramesExtracted: 0,
      totalFramesAccepted: 0,
      totalOutputFramesDrained: 0,
      postSeekFramesAccepted: 0,
      postSeekFramesDrained: 0,
      decoderBenignFormatChangeCount: 0,
      providerUnderrunEvents: 0,
      providerFramesZeroFilled: 0,
      providerForwardSkipFrames: 0,
      providerRewindRejects: 0,
      coordinatorSilenceCount: 0,
      nativeAcceptedChecksumHex: '',
      nativeOutputDrainChecksumHex: '',
      kotlinAcceptedChecksumHex: '',
      maxFramesPerMix: 0,
      sourceAvailableReadFrames: -1,
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

  /// Invokes the Android True-DAG Phase 4 real MediaExtractor/MediaCodec decoder
  /// closed-loop native audio graph pipeline diagnostic proof smoke harness.
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
  static Future<VGRealDecoderPipelineSmokeReport>
  runAndroidDagPhase4RealDecoderPipelineSmoke({
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
      return VGRealDecoderPipelineSmokeReport.fromMap(raw);
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
    return other is VGRealDecoderPipelineSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.formatProbeOk == formatProbeOk &&
        other.decoderBenignFormatChangeObserved ==
            decoderBenignFormatChangeObserved &&
        other.decoderEosReachedOk == decoderEosReachedOk &&
        other.sourcePartialWriteObserved == sourcePartialWriteObserved &&
        other.sourceRingFullObserved == sourceRingFullObserved &&
        other.outputBackpressureObserved == outputBackpressureObserved &&
        other.checksumIdentityOk == checksumIdentityOk &&
        other.frameAccountingOk == frameAccountingOk &&
        other.seekOk == seekOk &&
        other.tailFlushOk == tailFlushOk &&
        other.noUnderrunOk == noUnderrunOk &&
        other.noSilenceOk == noSilenceOk &&
        other.noRingPushShortfallOk == noRingPushShortfallOk &&
        other.noForwardSkipOk == noForwardSkipOk &&
        other.noRewindRejectOk == noRewindRejectOk &&
        other.finalNotTerminalOk == finalNotTerminalOk &&
        other.finalSeekAckClearOk == finalSeekAckClearOk &&
        other.zeroNativeSteadyStateAllocationOk ==
            zeroNativeSteadyStateAllocationOk &&
        other.ownerThreadOk == ownerThreadOk &&
        other.lifecycleOk == lifecycleOk &&
        other.canonical == canonical &&
        other.sampleRate == sampleRate &&
        other.channelCount == channelCount &&
        other.pcmEncoding == pcmEncoding &&
        other.totalFramesExtracted == totalFramesExtracted &&
        other.totalFramesAccepted == totalFramesAccepted &&
        other.totalOutputFramesDrained == totalOutputFramesDrained &&
        other.postSeekFramesAccepted == postSeekFramesAccepted &&
        other.postSeekFramesDrained == postSeekFramesDrained &&
        other.decoderBenignFormatChangeCount ==
            decoderBenignFormatChangeCount &&
        other.providerUnderrunEvents == providerUnderrunEvents &&
        other.providerFramesZeroFilled == providerFramesZeroFilled &&
        other.providerForwardSkipFrames == providerForwardSkipFrames &&
        other.providerRewindRejects == providerRewindRejects &&
        other.coordinatorSilenceCount == coordinatorSilenceCount &&
        other.nativeAcceptedChecksumHex == nativeAcceptedChecksumHex &&
        other.nativeOutputDrainChecksumHex == nativeOutputDrainChecksumHex &&
        other.kotlinAcceptedChecksumHex == kotlinAcceptedChecksumHex &&
        other.maxFramesPerMix == maxFramesPerMix &&
        other.sourceAvailableReadFrames == sourceAvailableReadFrames &&
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
    decoderBenignFormatChangeObserved,
    decoderEosReachedOk,
    sourcePartialWriteObserved,
    sourceRingFullObserved,
    outputBackpressureObserved,
    checksumIdentityOk,
    frameAccountingOk,
    seekOk,
    tailFlushOk,
    noUnderrunOk,
    noSilenceOk,
    noRingPushShortfallOk,
    noForwardSkipOk,
    noRewindRejectOk,
    finalNotTerminalOk,
    finalSeekAckClearOk,
    zeroNativeSteadyStateAllocationOk,
    ownerThreadOk,
    lifecycleOk,
    canonical,
    sampleRate,
    channelCount,
    pcmEncoding,
    totalFramesExtracted,
    totalFramesAccepted,
    totalOutputFramesDrained,
    postSeekFramesAccepted,
    postSeekFramesDrained,
    decoderBenignFormatChangeCount,
    providerUnderrunEvents,
    providerFramesZeroFilled,
    providerForwardSkipFrames,
    providerRewindRejects,
    coordinatorSilenceCount,
    nativeAcceptedChecksumHex,
    nativeOutputDrainChecksumHex,
    kotlinAcceptedChecksumHex,
    maxFramesPerMix,
    sourceAvailableReadFrames,
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
      'VGRealDecoderPipelineSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'formatProbeOk: $formatProbeOk, '
      'decoderBenignFormatChangeObserved: $decoderBenignFormatChangeObserved, '
      'decoderEosReachedOk: $decoderEosReachedOk, '
      'sourcePartialWriteObserved: $sourcePartialWriteObserved, '
      'sourceRingFullObserved: $sourceRingFullObserved, '
      'outputBackpressureObserved: $outputBackpressureObserved, '
      'checksumIdentityOk: $checksumIdentityOk, '
      'frameAccountingOk: $frameAccountingOk, '
      'seekOk: $seekOk, '
      'tailFlushOk: $tailFlushOk, '
      'noUnderrunOk: $noUnderrunOk, '
      'noSilenceOk: $noSilenceOk, '
      'noRingPushShortfallOk: $noRingPushShortfallOk, '
      'noForwardSkipOk: $noForwardSkipOk, '
      'noRewindRejectOk: $noRewindRejectOk, '
      'finalNotTerminalOk: $finalNotTerminalOk, '
      'finalSeekAckClearOk: $finalSeekAckClearOk, '
      'zeroNativeSteadyStateAllocationOk: $zeroNativeSteadyStateAllocationOk, '
      'ownerThreadOk: $ownerThreadOk, '
      'lifecycleOk: $lifecycleOk, '
      'canonical: $canonical, '
      'sampleRate: $sampleRate, '
      'channelCount: $channelCount, '
      'pcmEncoding: $pcmEncoding, '
      'totalFramesExtracted: $totalFramesExtracted, '
      'totalFramesAccepted: $totalFramesAccepted, '
      'totalOutputFramesDrained: $totalOutputFramesDrained, '
      'postSeekFramesAccepted: $postSeekFramesAccepted, '
      'postSeekFramesDrained: $postSeekFramesDrained, '
      'decoderBenignFormatChangeCount: $decoderBenignFormatChangeCount, '
      'providerUnderrunEvents: $providerUnderrunEvents, '
      'providerFramesZeroFilled: $providerFramesZeroFilled, '
      'providerForwardSkipFrames: $providerForwardSkipFrames, '
      'providerRewindRejects: $providerRewindRejects, '
      'coordinatorSilenceCount: $coordinatorSilenceCount, '
      'nativeAcceptedChecksumHex: $nativeAcceptedChecksumHex, '
      'nativeOutputDrainChecksumHex: $nativeOutputDrainChecksumHex, '
      'kotlinAcceptedChecksumHex: $kotlinAcceptedChecksumHex, '
      'maxFramesPerMix: $maxFramesPerMix, '
      'sourceAvailableReadFrames: $sourceAvailableReadFrames, '
      'outputAvailableReadFrames: $outputAvailableReadFrames, '
      'dispatchCount: $dispatchCount, '
      'nextDispatchFrame: $nextDispatchFrame, '
      'nativeLastStatus: $nativeLastStatus, '
      'lanes: $lanes, '
      'metrics: $metrics, '
      'raw: $raw, '
      'lastError: $lastError)';
}
