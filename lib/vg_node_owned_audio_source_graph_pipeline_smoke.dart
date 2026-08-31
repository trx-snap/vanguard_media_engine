// vg_node_owned_audio_source_graph_pipeline_smoke.dart
// vanguard_media_engine - P4-AUDIO-DECODER-SOURCE-NODE-WIRING: Android True-DAG Phase 4
// node-owned decoded audio source closed-loop native audio graph pipeline diagnostic smoke foundation
// (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidNodeOwnedAudioSourceGraphPipelineSmoke` MethodChannel route.
// Diagnostic-only - validates the session-scoped node-owned-source closed-loop native audio
// graph pipeline JNI seam: DecodedAudioPcmSourceNode (6-arg constructor) owns its source
// ring/writer/provider triple by composition, and GraphAudioScheduler auto-discovers the
// provider from graph topology alone (tag-dispatched constructor; no external provider map,
// no hybrid routing).
// Single routed track at unit gain with caller-derived clock ticks.
//
// Honest non-claims (Proof Boundary):
// diagnostic_node_owned_decoded_audio_source_ring_provider_wiring_proof_only_source_node_owns_ring_writer_provider_by_composition_scheduler_auto_discovers_provider_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_no_hybrid_routing_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_mediacodec_no_mediaextractor_no_cpp_os_decoder_ownership_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_no_audio_focus_no_route_no_dead_object_no_audible_no_speaker_no_latency_no_glitch_claims_no_streaming_no_cache_no_ios_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_destroy_idempotent_any_thread_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_single_routed_track_unit_gain_only_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGNodeOwnedAudioSourceGraphPipelineSmokeReport.runAndroidNodeOwnedAudioSourceGraphPipelineSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGNodeOwnedAudioSourceGraphPipelineSmokeReport {
  const VGNodeOwnedAudioSourceGraphPipelineSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.invalidCreateRejectedOk,
    required this.routeDiscoveryOk,
    required this.nodeOwnsRingOk,
    required this.checksumIdentityOk,
    required this.frameAccountingOk,
    required this.seekOk,
    required this.underrunGateOk,
    required this.tailFlushOk,
    required this.noUnderrunOk,
    required this.noSilenceOk,
    required this.zeroNativeSteadyStateAllocationOk,
    required this.lifecycleOk,
    required this.routedSourceCount,
    required this.routedSourceId0,
    required this.nodeOwnsRing,
    required this.totalFramesAccepted,
    required this.totalOutputFramesDrained,
    required this.providerUnderrunEvents,
    required this.providerFramesZeroFilled,
    required this.providerForwardSkipFrames,
    required this.providerRewindRejects,
    required this.coordinatorSilenceCount,
    required this.dispatchCount,
    required this.nativeAcceptedChecksumHex,
    required this.nativeOutputDrainChecksumHex,
    required this.kotlinAcceptedChecksumHex,
    required this.sourceAvailableReadFrames,
    required this.outputAvailableReadFrames,
    required this.schedulerTrackScratchCapacitySamples,
    required this.schedulerTrackScratchCapacityTracks,
    required this.sourceRingStorageCapacitySamples,
    required this.outputRingStorageCapacitySamples,
    required this.lanes,
    required this.metrics,
    required this.raw,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidNodeOwnedAudioSourceGraphPipelineSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_AUDIO_DECODER_SOURCE_NODE_WIRING_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_AUDIO_DECODER_SOURCE_NODE_WIRING_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'diagnostic_node_owned_decoded_audio_source_ring_provider_wiring_proof_only_source_node_owns_ring_writer_provider_by_composition_scheduler_auto_discovers_provider_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_no_hybrid_routing_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_mediacodec_no_mediaextractor_no_cpp_os_decoder_ownership_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_no_audio_focus_no_route_no_dead_object_no_audible_no_speaker_no_latency_no_glitch_claims_no_streaming_no_cache_no_ios_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_destroy_idempotent_any_thread_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_single_routed_track_unit_gain_only_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim';

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

  // ---- Lanes (12 lanes) ---------------------------------------------------

  /// Whether fail-closed invalid constructor parameters were properly rejected.
  final bool invalidCreateRejectedOk;

  /// Whether scheduler auto-discovered the single node-owned source from topology.
  final bool routeDiscoveryOk;

  /// Whether DecodedAudioPcmSourceNode owns the ring/writer/provider triple.
  final bool nodeOwnsRingOk;

  /// Whether 3-way checksum identity holds (Kotlin accepted == native accepted == native drained).
  final bool checksumIdentityOk;

  /// Whether total accepted frames equals total drained frames in lockstep.
  final bool frameAccountingOk;

  /// Whether forward-only seek re-anchored cursor cleanly with zero discards.
  final bool seekOk;

  /// Whether underrun gate deferred insufficient source sub-window correctly.
  final bool underrunGateOk;

  /// Whether writer EOS tail flush stepped partial window and completed cleanly.
  final bool tailFlushOk;

  /// Whether no provider underrun events, zero-fills, or rewind rejects occurred.
  final bool noUnderrunOk;

  /// Whether no coordinator silence windows occurred.
  final bool noSilenceOk;

  /// Whether ring and scheduler capacities remained constant across dispatches.
  final bool zeroNativeSteadyStateAllocationOk;

  /// Whether session lifecycle creation, rejection, and destroy were idempotent.
  final bool lifecycleOk;

  // ---- Metrics (20 metrics) -----------------------------------------------

  /// Number of routed source nodes discovered in topology (must be 1).
  final int routedSourceCount;

  /// Node ID of the first routed source node (must be 'node_owned_pipeline_src').
  final String routedSourceId0;

  /// Whether the node owns the ring buffer.
  final bool nodeOwnsRing;

  /// Total frames accepted into the pipeline via the node-owned writer.
  final int totalFramesAccepted;

  /// Total frames drained from the output ring.
  final int totalOutputFramesDrained;

  /// Provider underrun events count (must be 0).
  final int providerUnderrunEvents;

  /// Provider frames zero-filled count (must be 0).
  final int providerFramesZeroFilled;

  /// Provider forward frame skips count (must be 0).
  final int providerForwardSkipFrames;

  /// Provider rewind frame rejects count (must be 0).
  final int providerRewindRejects;

  /// Coordinator silence windows count (must be 0).
  final int coordinatorSilenceCount;

  /// Total dispatch cycles executed during the run (must be >= 50).
  final int dispatchCount;

  /// 64-bit hexadecimal checksum computed on the native accepted side.
  final String nativeAcceptedChecksumHex;

  /// 64-bit hexadecimal checksum computed on the native output drain side.
  final String nativeOutputDrainChecksumHex;

  /// 64-bit hexadecimal checksum computed on the Kotlin accepted side.
  final String kotlinAcceptedChecksumHex;

  /// Source ring available read frames at last snapshot (must be 0 at end of test).
  final int sourceAvailableReadFrames;

  /// Output ring available read frames at last snapshot (must be 0 at end of test).
  final int outputAvailableReadFrames;

  /// Scheduler track scratch capacity in samples (must be > 0).
  final int schedulerTrackScratchCapacitySamples;

  /// Scheduler track scratch capacity in tracks (must be > 0).
  final int schedulerTrackScratchCapacityTracks;

  /// Source ring storage capacity in samples (must be > 0).
  final int sourceRingStorageCapacitySamples;

  /// Output ring storage capacity in samples (must be > 0).
  final int outputRingStorageCapacitySamples;

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
  /// are non-empty and equal, and [checksumIdentityOk] is true.
  bool get checksumsMatch =>
      kotlinAcceptedChecksumHex.isNotEmpty &&
      nativeAcceptedChecksumHex.isNotEmpty &&
      nativeOutputDrainChecksumHex.isNotEmpty &&
      kotlinAcceptedChecksumHex == nativeAcceptedChecksumHex &&
      nativeAcceptedChecksumHex == nativeOutputDrainChecksumHex &&
      checksumIdentityOk;

  /// Whether all native diagnostic lanes passed according to the
  /// P4-AUDIO-DECODER-SOURCE-NODE-WIRING verification contract.
  bool get allNativeLanesPass =>
      pass &&
      status.toLowerCase() == 'pass' &&
      marker == passMarkerConstant &&
      hasCanonicalProofBoundary &&
      invalidCreateRejectedOk &&
      routeDiscoveryOk &&
      nodeOwnsRingOk &&
      checksumIdentityOk &&
      frameAccountingOk &&
      seekOk &&
      underrunGateOk &&
      tailFlushOk &&
      noUnderrunOk &&
      noSilenceOk &&
      zeroNativeSteadyStateAllocationOk &&
      lifecycleOk &&
      routedSourceCount == 1 &&
      routedSourceId0 == expectedSourceNodeId &&
      nodeOwnsRing &&
      checksumsMatch &&
      totalFramesAccepted > 0 &&
      totalFramesAccepted == totalOutputFramesDrained &&
      providerUnderrunEvents == 0 &&
      providerFramesZeroFilled == 0 &&
      providerForwardSkipFrames == 0 &&
      providerRewindRejects == 0 &&
      coordinatorSilenceCount == 0 &&
      sourceAvailableReadFrames == 0 &&
      outputAvailableReadFrames == 0 &&
      dispatchCount >= 50 &&
      schedulerTrackScratchCapacitySamples > 0 &&
      schedulerTrackScratchCapacityTracks > 0 &&
      sourceRingStorageCapacitySamples > 0 &&
      outputRingStorageCapacitySamples > 0 &&
      (lastError.isEmpty || lastError == 'none' || lastError == 'null');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGNodeOwnedAudioSourceGraphPipelineSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGNodeOwnedAudioSourceGraphPipelineSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        invalidCreateRejectedOk: false,
        routeDiscoveryOk: false,
        nodeOwnsRingOk: false,
        checksumIdentityOk: false,
        frameAccountingOk: false,
        seekOk: false,
        underrunGateOk: false,
        tailFlushOk: false,
        noUnderrunOk: false,
        noSilenceOk: false,
        zeroNativeSteadyStateAllocationOk: false,
        lifecycleOk: false,
        routedSourceCount: -1,
        routedSourceId0: '',
        nodeOwnsRing: false,
        totalFramesAccepted: 0,
        totalOutputFramesDrained: 0,
        providerUnderrunEvents: -1,
        providerFramesZeroFilled: -1,
        providerForwardSkipFrames: -1,
        providerRewindRejects: -1,
        coordinatorSilenceCount: -1,
        dispatchCount: 0,
        nativeAcceptedChecksumHex: '',
        nativeOutputDrainChecksumHex: '',
        kotlinAcceptedChecksumHex: '',
        sourceAvailableReadFrames: -1,
        outputAvailableReadFrames: -1,
        schedulerTrackScratchCapacitySamples: -1,
        schedulerTrackScratchCapacityTracks: -1,
        sourceRingStorageCapacitySamples: -1,
        outputRingStorageCapacitySamples: -1,
        lanes: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
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

    final invalidCreateRejectedOk = parseBool('invalidCreateRejectedOk');
    final routeDiscoveryOk = parseBool('routeDiscoveryOk');
    final nodeOwnsRingOk = parseBool('nodeOwnsRingOk');
    final checksumIdentityOk = parseBool('checksumIdentityOk');
    final frameAccountingOk = parseBool('frameAccountingOk');
    final seekOk = parseBool('seekOk');
    final underrunGateOk = parseBool('underrunGateOk');
    final tailFlushOk = parseBool('tailFlushOk');
    final noUnderrunOk = parseBool('noUnderrunOk');
    final noSilenceOk = parseBool('noSilenceOk');
    final zeroNativeSteadyStateAllocationOk = parseBool(
      'zeroNativeSteadyStateAllocationOk',
    );
    final lifecycleOk = parseBool('lifecycleOk');

    final routedSourceCount = parseInt('routedSourceCount', -1);
    final routedSourceId0 = parseString('routedSourceId0');
    final nodeOwnsRing = parseBool('nodeOwnsRing');
    final totalFramesAccepted = parseInt('totalFramesAccepted');
    final totalOutputFramesDrained = parseInt('totalOutputFramesDrained');
    final providerUnderrunEvents = parseInt('providerUnderrunEvents', -1);
    final providerFramesZeroFilled = parseInt('providerFramesZeroFilled', -1);
    final providerForwardSkipFrames = parseInt('providerForwardSkipFrames', -1);
    final providerRewindRejects = parseInt('providerRewindRejects', -1);
    final coordinatorSilenceCount = parseInt('coordinatorSilenceCount', -1);
    final dispatchCount = parseInt('dispatchCount');
    final nativeAcceptedChecksumHex = parseString('nativeAcceptedChecksumHex');
    final nativeOutputDrainChecksumHex = parseString(
      'nativeOutputDrainChecksumHex',
    );
    final kotlinAcceptedChecksumHex = parseString('kotlinAcceptedChecksumHex');
    final sourceAvailableReadFrames = parseInt('sourceAvailableReadFrames', -1);
    final outputAvailableReadFrames = parseInt('outputAvailableReadFrames', -1);
    final schedulerTrackScratchCapacitySamples = parseInt(
      'schedulerTrackScratchCapacitySamples',
      -1,
    );
    final schedulerTrackScratchCapacityTracks = parseInt(
      'schedulerTrackScratchCapacityTracks',
      -1,
    );
    final sourceRingStorageCapacitySamples = parseInt(
      'sourceRingStorageCapacitySamples',
      -1,
    );
    final outputRingStorageCapacitySamples = parseInt(
      'outputRingStorageCapacitySamples',
      -1,
    );

    final lastError = parseString(
      'lastError',
      failureReason.isNotEmpty ? failureReason : (pass ? '' : status),
    );

    final finalLanes = <String, Object?>{
      'invalidCreateRejectedOk': invalidCreateRejectedOk,
      'routeDiscoveryOk': routeDiscoveryOk,
      'nodeOwnsRingOk': nodeOwnsRingOk,
      'checksumIdentityOk': checksumIdentityOk,
      'frameAccountingOk': frameAccountingOk,
      'seekOk': seekOk,
      'underrunGateOk': underrunGateOk,
      'tailFlushOk': tailFlushOk,
      'noUnderrunOk': noUnderrunOk,
      'noSilenceOk': noSilenceOk,
      'zeroNativeSteadyStateAllocationOk': zeroNativeSteadyStateAllocationOk,
      'lifecycleOk': lifecycleOk,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{
      'routedSourceCount': routedSourceCount,
      'routedSourceId0': routedSourceId0,
      'nodeOwnsRing': nodeOwnsRing,
      'totalFramesAccepted': totalFramesAccepted,
      'totalOutputFramesDrained': totalOutputFramesDrained,
      'providerUnderrunEvents': providerUnderrunEvents,
      'providerFramesZeroFilled': providerFramesZeroFilled,
      'providerForwardSkipFrames': providerForwardSkipFrames,
      'providerRewindRejects': providerRewindRejects,
      'coordinatorSilenceCount': coordinatorSilenceCount,
      'dispatchCount': dispatchCount,
      'nativeAcceptedChecksumHex': nativeAcceptedChecksumHex,
      'nativeOutputDrainChecksumHex': nativeOutputDrainChecksumHex,
      'kotlinAcceptedChecksumHex': kotlinAcceptedChecksumHex,
      'sourceAvailableReadFrames': sourceAvailableReadFrames,
      'outputAvailableReadFrames': outputAvailableReadFrames,
      'schedulerTrackScratchCapacitySamples':
          schedulerTrackScratchCapacitySamples,
      'schedulerTrackScratchCapacityTracks':
          schedulerTrackScratchCapacityTracks,
      'sourceRingStorageCapacitySamples': sourceRingStorageCapacitySamples,
      'outputRingStorageCapacitySamples': outputRingStorageCapacitySamples,
      ...parsedMetrics,
    };

    return VGNodeOwnedAudioSourceGraphPipelineSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      details: details,
      invalidCreateRejectedOk: invalidCreateRejectedOk,
      routeDiscoveryOk: routeDiscoveryOk,
      nodeOwnsRingOk: nodeOwnsRingOk,
      checksumIdentityOk: checksumIdentityOk,
      frameAccountingOk: frameAccountingOk,
      seekOk: seekOk,
      underrunGateOk: underrunGateOk,
      tailFlushOk: tailFlushOk,
      noUnderrunOk: noUnderrunOk,
      noSilenceOk: noSilenceOk,
      zeroNativeSteadyStateAllocationOk: zeroNativeSteadyStateAllocationOk,
      lifecycleOk: lifecycleOk,
      routedSourceCount: routedSourceCount,
      routedSourceId0: routedSourceId0,
      nodeOwnsRing: nodeOwnsRing,
      totalFramesAccepted: totalFramesAccepted,
      totalOutputFramesDrained: totalOutputFramesDrained,
      providerUnderrunEvents: providerUnderrunEvents,
      providerFramesZeroFilled: providerFramesZeroFilled,
      providerForwardSkipFrames: providerForwardSkipFrames,
      providerRewindRejects: providerRewindRejects,
      coordinatorSilenceCount: coordinatorSilenceCount,
      dispatchCount: dispatchCount,
      nativeAcceptedChecksumHex: nativeAcceptedChecksumHex,
      nativeOutputDrainChecksumHex: nativeOutputDrainChecksumHex,
      kotlinAcceptedChecksumHex: kotlinAcceptedChecksumHex,
      sourceAvailableReadFrames: sourceAvailableReadFrames,
      outputAvailableReadFrames: outputAvailableReadFrames,
      schedulerTrackScratchCapacitySamples:
          schedulerTrackScratchCapacitySamples,
      schedulerTrackScratchCapacityTracks: schedulerTrackScratchCapacityTracks,
      sourceRingStorageCapacitySamples: sourceRingStorageCapacitySamples,
      outputRingStorageCapacitySamples: outputRingStorageCapacitySamples,
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

  static VGNodeOwnedAudioSourceGraphPipelineSmokeReport
  _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      'invalidCreateRejectedOk': false,
      'routeDiscoveryOk': false,
      'nodeOwnsRingOk': false,
      'checksumIdentityOk': false,
      'frameAccountingOk': false,
      'seekOk': false,
      'underrunGateOk': false,
      'tailFlushOk': false,
      'noUnderrunOk': false,
      'noSilenceOk': false,
      'zeroNativeSteadyStateAllocationOk': false,
      'lifecycleOk': false,
    };
    final metrics = <String, Object?>{
      'routedSourceCount': -1,
      'routedSourceId0': '',
      'nodeOwnsRing': false,
      'totalFramesAccepted': 0,
      'totalOutputFramesDrained': 0,
      'providerUnderrunEvents': -1,
      'providerFramesZeroFilled': -1,
      'providerForwardSkipFrames': -1,
      'providerRewindRejects': -1,
      'coordinatorSilenceCount': -1,
      'dispatchCount': 0,
      'nativeAcceptedChecksumHex': '',
      'nativeOutputDrainChecksumHex': '',
      'kotlinAcceptedChecksumHex': '',
      'sourceAvailableReadFrames': -1,
      'outputAvailableReadFrames': -1,
      'schedulerTrackScratchCapacitySamples': -1,
      'schedulerTrackScratchCapacityTracks': -1,
      'sourceRingStorageCapacitySamples': -1,
      'outputRingStorageCapacitySamples': -1,
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGNodeOwnedAudioSourceGraphPipelineSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      invalidCreateRejectedOk: false,
      routeDiscoveryOk: false,
      nodeOwnsRingOk: false,
      checksumIdentityOk: false,
      frameAccountingOk: false,
      seekOk: false,
      underrunGateOk: false,
      tailFlushOk: false,
      noUnderrunOk: false,
      noSilenceOk: false,
      zeroNativeSteadyStateAllocationOk: false,
      lifecycleOk: false,
      routedSourceCount: -1,
      routedSourceId0: '',
      nodeOwnsRing: false,
      totalFramesAccepted: 0,
      totalOutputFramesDrained: 0,
      providerUnderrunEvents: -1,
      providerFramesZeroFilled: -1,
      providerForwardSkipFrames: -1,
      providerRewindRejects: -1,
      coordinatorSilenceCount: -1,
      dispatchCount: 0,
      nativeAcceptedChecksumHex: '',
      nativeOutputDrainChecksumHex: '',
      kotlinAcceptedChecksumHex: '',
      sourceAvailableReadFrames: -1,
      outputAvailableReadFrames: -1,
      schedulerTrackScratchCapacitySamples: -1,
      schedulerTrackScratchCapacityTracks: -1,
      sourceRingStorageCapacitySamples: -1,
      outputRingStorageCapacitySamples: -1,
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      raw: Map<String, String>.unmodifiable(<String, String>{
        'status': 'FAIL',
        'reason': reason,
      }),
      lastError: lastError,
    );
  }

  /// Invokes the Android True-DAG Phase 4 node-owned decoded audio source
  /// closed-loop native audio graph pipeline diagnostic proof smoke harness.
  ///
  /// [sampleRate] sampling rate in Hz (default 48000).
  /// [channelCount] audio channel count (default 2).
  /// [sourceRingCapacityFrames] capacity of source ring in frames (default 8192).
  /// [outputRingCapacityFrames] capacity of output ring in frames (default 4096).
  /// [maxFramesPerMix] max frames per mix dispatch cycle (default 256).
  /// [preSeekWindows] number of pre-seek identity windows (default 32).
  /// [postSeekWindows] number of post-seek identity windows (default 32).
  /// [timeout] optionally bounds the invocation; deadlineMs is passed to Kotlin.
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGNodeOwnedAudioSourceGraphPipelineSmokeReport>
  runAndroidNodeOwnedAudioSourceGraphPipelineSmoke({
    int sampleRate = 48000,
    int channelCount = 2,
    int sourceRingCapacityFrames = 8192,
    int outputRingCapacityFrames = 4096,
    int maxFramesPerMix = 256,
    int preSeekWindows = 32,
    int postSeekWindows = 32,
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final args = <String, Object?>{
      'sampleRate': sampleRate,
      'channelCount': channelCount,
      'sourceRingCapacityFrames': sourceRingCapacityFrames,
      'outputRingCapacityFrames': outputRingCapacityFrames,
      'maxFramesPerMix': maxFramesPerMix,
      'preSeekWindows': preSeekWindows,
      'postSeekWindows': postSeekWindows,
      'deadlineMs': timeout != null ? timeout.inMilliseconds : 30000,
    };
    try {
      final future = ch.invokeMethod<Object?>(methodName, args);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(raw);
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
    return other is VGNodeOwnedAudioSourceGraphPipelineSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.invalidCreateRejectedOk == invalidCreateRejectedOk &&
        other.routeDiscoveryOk == routeDiscoveryOk &&
        other.nodeOwnsRingOk == nodeOwnsRingOk &&
        other.checksumIdentityOk == checksumIdentityOk &&
        other.frameAccountingOk == frameAccountingOk &&
        other.seekOk == seekOk &&
        other.underrunGateOk == underrunGateOk &&
        other.tailFlushOk == tailFlushOk &&
        other.noUnderrunOk == noUnderrunOk &&
        other.noSilenceOk == noSilenceOk &&
        other.zeroNativeSteadyStateAllocationOk ==
            zeroNativeSteadyStateAllocationOk &&
        other.lifecycleOk == lifecycleOk &&
        other.routedSourceCount == routedSourceCount &&
        other.routedSourceId0 == routedSourceId0 &&
        other.nodeOwnsRing == nodeOwnsRing &&
        other.totalFramesAccepted == totalFramesAccepted &&
        other.totalOutputFramesDrained == totalOutputFramesDrained &&
        other.providerUnderrunEvents == providerUnderrunEvents &&
        other.providerFramesZeroFilled == providerFramesZeroFilled &&
        other.providerForwardSkipFrames == providerForwardSkipFrames &&
        other.providerRewindRejects == providerRewindRejects &&
        other.coordinatorSilenceCount == coordinatorSilenceCount &&
        other.dispatchCount == dispatchCount &&
        other.nativeAcceptedChecksumHex == nativeAcceptedChecksumHex &&
        other.nativeOutputDrainChecksumHex == nativeOutputDrainChecksumHex &&
        other.kotlinAcceptedChecksumHex == kotlinAcceptedChecksumHex &&
        other.sourceAvailableReadFrames == sourceAvailableReadFrames &&
        other.outputAvailableReadFrames == outputAvailableReadFrames &&
        other.schedulerTrackScratchCapacitySamples ==
            schedulerTrackScratchCapacitySamples &&
        other.schedulerTrackScratchCapacityTracks ==
            schedulerTrackScratchCapacityTracks &&
        other.sourceRingStorageCapacitySamples ==
            sourceRingStorageCapacitySamples &&
        other.outputRingStorageCapacitySamples ==
            outputRingStorageCapacitySamples &&
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
    invalidCreateRejectedOk,
    routeDiscoveryOk,
    nodeOwnsRingOk,
    checksumIdentityOk,
    frameAccountingOk,
    seekOk,
    underrunGateOk,
    tailFlushOk,
    noUnderrunOk,
    noSilenceOk,
    zeroNativeSteadyStateAllocationOk,
    lifecycleOk,
    routedSourceCount,
    routedSourceId0,
    nodeOwnsRing,
    totalFramesAccepted,
    totalOutputFramesDrained,
    providerUnderrunEvents,
    providerFramesZeroFilled,
    providerForwardSkipFrames,
    providerRewindRejects,
    coordinatorSilenceCount,
    dispatchCount,
    nativeAcceptedChecksumHex,
    nativeOutputDrainChecksumHex,
    kotlinAcceptedChecksumHex,
    sourceAvailableReadFrames,
    outputAvailableReadFrames,
    schedulerTrackScratchCapacitySamples,
    schedulerTrackScratchCapacityTracks,
    sourceRingStorageCapacitySamples,
    outputRingStorageCapacitySamples,
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
      'VGNodeOwnedAudioSourceGraphPipelineSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'invalidCreateRejectedOk: $invalidCreateRejectedOk, '
      'routeDiscoveryOk: $routeDiscoveryOk, '
      'nodeOwnsRingOk: $nodeOwnsRingOk, '
      'checksumIdentityOk: $checksumIdentityOk, '
      'frameAccountingOk: $frameAccountingOk, '
      'seekOk: $seekOk, '
      'underrunGateOk: $underrunGateOk, '
      'tailFlushOk: $tailFlushOk, '
      'noUnderrunOk: $noUnderrunOk, '
      'noSilenceOk: $noSilenceOk, '
      'zeroNativeSteadyStateAllocationOk: $zeroNativeSteadyStateAllocationOk, '
      'lifecycleOk: $lifecycleOk, '
      'routedSourceCount: $routedSourceCount, '
      'routedSourceId0: $routedSourceId0, '
      'nodeOwnsRing: $nodeOwnsRing, '
      'totalFramesAccepted: $totalFramesAccepted, '
      'totalOutputFramesDrained: $totalOutputFramesDrained, '
      'providerUnderrunEvents: $providerUnderrunEvents, '
      'providerFramesZeroFilled: $providerFramesZeroFilled, '
      'providerForwardSkipFrames: $providerForwardSkipFrames, '
      'providerRewindRejects: $providerRewindRejects, '
      'coordinatorSilenceCount: $coordinatorSilenceCount, '
      'dispatchCount: $dispatchCount, '
      'nativeAcceptedChecksumHex: $nativeAcceptedChecksumHex, '
      'nativeOutputDrainChecksumHex: $nativeOutputDrainChecksumHex, '
      'kotlinAcceptedChecksumHex: $kotlinAcceptedChecksumHex, '
      'sourceAvailableReadFrames: $sourceAvailableReadFrames, '
      'outputAvailableReadFrames: $outputAvailableReadFrames, '
      'schedulerTrackScratchCapacitySamples: $schedulerTrackScratchCapacitySamples, '
      'schedulerTrackScratchCapacityTracks: $schedulerTrackScratchCapacityTracks, '
      'sourceRingStorageCapacitySamples: $sourceRingStorageCapacitySamples, '
      'outputRingStorageCapacitySamples: $outputRingStorageCapacitySamples, '
      'lanes: $lanes, '
      'metrics: $metrics, '
      'raw: $raw, '
      'lastError: $lastError)';
}
