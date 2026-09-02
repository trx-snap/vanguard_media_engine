// vg_realtime_playback_pipeline_seek_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SEEK (Y6c): Android True-DAG Phase 4
// realtime playback pipeline seek diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimePlaybackPipelineSeekSmoke` MethodChannel route.
// Diagnostic-only - validates real MediaExtractor / MediaCodec synchronous
// PCM16 decode feeding into the Y5a external ingest seam, native Y1 transport,
// and non-zero-gain AudioTrack sink with deterministic mid-stream seek ordering:
// pre-roll -> hold frame -> initial drain -> quiescence -> sink park ->
// pre-seek snapshot -> transport pause -> sink flush on sink thread ->
// transport seek while PAUSED -> feed re-anchor + deliberate stale probe ->
// post-seek pre-roll while PAUSED -> sink unpark -> transport resume -> EOS.
//
// Required proof lanes (18 native gates + proofBoundaryOk + canonical = 20 total):
//   1. formatProbeOk: format, duration, channel count, sample rate, and MIME probed successfully
//   2. preRollOk: pre-roll while PREPARED until ring_full or declared end fits
//   3. initialDrainOk: positive initial sink writes before park/pause
//   4. seekQuiesceAccountingOk: pipeline quiescence at hold frame with pushed == drained == hold
//   5. pauseCommandOk: transport.pause() accepted and state moved to PAUSED
//   6. sinkPausedOk: AudioTrack PLAYSTATE_PAUSED held with zero violations
//   7. seekCommandOk: transport.seek(target) accepted while PAUSED with generation + 1
//   8. sinkFlushAtSeekOk: AudioTrack.flush() executed once on sink thread while paused
//   9. realDecoderSeekReanchorOk: decoder re-anchored on decode thread with valid gap padding
//  10. staleGenerationRejectedOk: stale pre-seek generation probe rejected before JNI
//  11. sinkResumedOk: sink unpark acked on sink thread with AudioTrack.play() and epoch base
//  12. postSeekDrainOk: sink drained and progressed post-resume to EOS
//  13. sinkWriteAccountingOk: two-epoch frames read from transport and written to sink match
//  14. checksumIdentityOk: decoder, native pushed, native drained, and sink checksums match
//  15. postSeekPlaybackHeadAdvancedOk: epoch-relative playback head progression post-unpark
//  16. transportCompletedOk: transport completed cleanly with lastError none
//  17. threadOwnershipOk: strict thread ownership across decode, transport, and sink threads
//  18. lifecycleDisposeOk: clean media and AudioTrack release, idempotent state machine dispose
//
// Honest non-claims (Proof Boundary):
// realtime_playback_pipeline_seek_diagnostic_only_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_single_track_one_forward_mid_stream_seek_while_paused_feed_held_at_window_aligned_anchor_quiescent_pushed_eq_drained_eq_anchor_discarded_0_sink_park_before_transport_pause_audiotrack_flush_once_on_sink_thread_before_transport_seek_feed_reanchor_generation_pinned_stale_pre_seek_ingest_rejected_before_jni_two_epoch_sink_accounting_epoch_relative_playback_head_no_presentation_clock_no_av_sync_no_latency_no_glitch_no_loudness_no_snr_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_interactive_ui_no_product_no_editor_no_app_wiring_no_ios_no_streaming_no_cache_no_cpp_changes

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimePlaybackPipelineSeekSmokeReport.runRealtimePlaybackPipelineSeekSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGRealtimePlaybackPipelineSeekSmokeReport {
  const VGRealtimePlaybackPipelineSeekSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.preRollOk,
    required this.initialDrainOk,
    required this.seekQuiesceAccountingOk,
    required this.pauseCommandOk,
    required this.sinkPausedOk,
    required this.seekCommandOk,
    required this.sinkFlushAtSeekOk,
    required this.realDecoderSeekReanchorOk,
    required this.staleGenerationRejectedOk,
    required this.sinkResumedOk,
    required this.postSeekDrainOk,
    required this.sinkWriteAccountingOk,
    required this.checksumIdentityOk,
    required this.postSeekPlaybackHeadAdvancedOk,
    required this.transportCompletedOk,
    required this.threadOwnershipOk,
    required this.lifecycleDisposeOk,
    required this.proofBoundaryOk,
    required this.canonical,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
    this.raw = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runRealtimePlaybackPipelineSeekSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'realtime_playback_pipeline_seek_diagnostic_only_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_single_track_one_forward_mid_stream_seek_while_paused_feed_held_at_window_aligned_anchor_quiescent_pushed_eq_drained_eq_anchor_discarded_0_sink_park_before_transport_pause_audiotrack_flush_once_on_sink_thread_before_transport_seek_feed_reanchor_generation_pinned_stale_pre_seek_ingest_rejected_before_jni_two_epoch_sink_accounting_epoch_relative_playback_head_no_presentation_clock_no_av_sync_no_latency_no_glitch_no_loudness_no_snr_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_interactive_ui_no_product_no_editor_no_app_wiring_no_ios_no_streaming_no_cache_no_cpp_changes';

  /// All required native gate keys that must be present and evaluate to true.
  static const List<String> requiredGateKeys = <String>[
    'formatProbeOk',
    'preRollOk',
    'initialDrainOk',
    'seekQuiesceAccountingOk',
    'pauseCommandOk',
    'sinkPausedOk',
    'seekCommandOk',
    'sinkFlushAtSeekOk',
    'realDecoderSeekReanchorOk',
    'staleGenerationRejectedOk',
    'sinkResumedOk',
    'postSeekDrainOk',
    'sinkWriteAccountingOk',
    'checksumIdentityOk',
    'postSeekPlaybackHeadAdvancedOk',
    'transportCompletedOk',
    'threadOwnershipOk',
    'lifecycleDisposeOk',
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

  // ---- Gates --------------------------------------------------------------

  /// Whether extractor probed format, duration, channel count, sample rate, and MIME.
  final bool formatProbeOk;

  /// Whether pre-roll completed while PREPARED until ring_full or stream end.
  final bool preRollOk;

  /// Whether initial sink writes and playback occurred before park/pause.
  final bool initialDrainOk;

  /// Whether pipeline quiescence at hold frame reached pushed == drained == hold.
  final bool seekQuiesceAccountingOk;

  /// Whether transport pause command was accepted and state moved to PAUSED.
  final bool pauseCommandOk;

  /// Whether sink observed AudioTrack PLAYSTATE_PAUSED with zero violations.
  final bool sinkPausedOk;

  /// Whether transport seek command was accepted and state stayed PAUSED.
  final bool seekCommandOk;

  /// Whether AudioTrack.flush() was executed once on the sink thread while paused.
  final bool sinkFlushAtSeekOk;

  /// Whether decoder re-anchored on decode thread with valid gap padding.
  final bool realDecoderSeekReanchorOk;

  /// Whether stale pre-seek generation probe was rejected before JNI.
  final bool staleGenerationRejectedOk;

  /// Whether sink unpark was acknowledged on the sink thread with AudioTrack.play().
  final bool sinkResumedOk;

  /// Whether sink drained and progressed post-resume to EOS.
  final bool postSeekDrainOk;

  /// Whether two-epoch sink write accounting matched declared frame counts.
  final bool sinkWriteAccountingOk;

  /// Whether decoder, native pushed, native drained, and sink checksums matched identically.
  final bool checksumIdentityOk;

  /// Whether epoch-relative playback head progression advanced post-unpark.
  final bool postSeekPlaybackHeadAdvancedOk;

  /// Whether transport completed into State.COMPLETED cleanly.
  final bool transportCompletedOk;

  /// Whether strict thread ownership across decode, transport, and sink threads held.
  final bool threadOwnershipOk;

  /// Whether lifecycle dispose released media, AudioTrack, and joined threads cleanly.
  final bool lifecycleDisposeOk;

  /// Whether proof boundary matched on native side.
  final bool proofBoundaryOk;

  /// Canonical pass indicator.
  final bool canonical;

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

  /// Raw telemetry payload string.
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

  /// Independent computation of verified pass.
  /// Requires pass==true, status=='pass', canonical PASS marker, exact proof boundary,
  /// empty failureReason, and every required gate true.
  bool get isVerifiedPass =>
      pass == true &&
      status.trim().toLowerCase() == 'pass' &&
      hasPassMarker &&
      hasCanonicalProofBoundary &&
      failureReason.isEmpty &&
      formatProbeOk &&
      preRollOk &&
      initialDrainOk &&
      seekQuiesceAccountingOk &&
      pauseCommandOk &&
      sinkPausedOk &&
      seekCommandOk &&
      sinkFlushAtSeekOk &&
      realDecoderSeekReanchorOk &&
      staleGenerationRejectedOk &&
      sinkResumedOk &&
      postSeekDrainOk &&
      sinkWriteAccountingOk &&
      checksumIdentityOk &&
      postSeekPlaybackHeadAdvancedOk &&
      transportCompletedOk &&
      threadOwnershipOk &&
      lifecycleDisposeOk;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealtimePlaybackPipelineSeekSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGRealtimePlaybackPipelineSeekSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        nativeProofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        formatProbeOk: false,
        preRollOk: false,
        initialDrainOk: false,
        seekQuiesceAccountingOk: false,
        pauseCommandOk: false,
        sinkPausedOk: false,
        seekCommandOk: false,
        sinkFlushAtSeekOk: false,
        realDecoderSeekReanchorOk: false,
        staleGenerationRejectedOk: false,
        sinkResumedOk: false,
        postSeekDrainOk: false,
        sinkWriteAccountingOk: false,
        checksumIdentityOk: false,
        postSeekPlaybackHeadAdvancedOk: false,
        transportCompletedOk: false,
        threadOwnershipOk: false,
        lifecycleDisposeOk: false,
        proofBoundaryOk: false,
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
      final v = raw[key] ?? parsedMetrics[key] ?? parsedLanes[key];
      if (v != null) return v.toString();
      return defaultValue;
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

    final missingGates = <String>[];
    for (final gateKey in requiredGateKeys) {
      if (parseBoolStrict(gateKey) == null) {
        missingGates.add(gateKey);
      }
    }

    final formatProbeOk = parseBool('formatProbeOk');
    final preRollOk = parseBool('preRollOk');
    final initialDrainOk = parseBool('initialDrainOk');
    final seekQuiesceAccountingOk = parseBool('seekQuiesceAccountingOk');
    final pauseCommandOk = parseBool('pauseCommandOk');
    final sinkPausedOk = parseBool('sinkPausedOk');
    final seekCommandOk = parseBool('seekCommandOk');
    final sinkFlushAtSeekOk = parseBool('sinkFlushAtSeekOk');
    final realDecoderSeekReanchorOk = parseBool('realDecoderSeekReanchorOk');
    final staleGenerationRejectedOk = parseBool('staleGenerationRejectedOk');
    final sinkResumedOk = parseBool('sinkResumedOk');
    final postSeekDrainOk = parseBool('postSeekDrainOk');
    final sinkWriteAccountingOk = parseBool('sinkWriteAccountingOk');
    final checksumIdentityOk = parseBool('checksumIdentityOk');
    final postSeekPlaybackHeadAdvancedOk = parseBool(
      'postSeekPlaybackHeadAdvancedOk',
    );
    final transportCompletedOk = parseBool('transportCompletedOk');
    final threadOwnershipOk = parseBool('threadOwnershipOk');
    final lifecycleDisposeOk = parseBool('lifecycleDisposeOk');
    final proofBoundaryOk = parseBool('proofBoundaryOk');
    final canonical = parseBool('canonical', rawPass && missingGates.isEmpty);

    final hasValidProofBoundary =
        proofBoundary == proofBoundaryConstant &&
        (nativeProofBoundary.isEmpty ||
            nativeProofBoundary == proofBoundaryConstant);
    final hasValidPassMarker = rawMarker == passMarkerConstant;

    final allRequiredGatesTrue =
        formatProbeOk &&
        preRollOk &&
        initialDrainOk &&
        seekQuiesceAccountingOk &&
        pauseCommandOk &&
        sinkPausedOk &&
        seekCommandOk &&
        sinkFlushAtSeekOk &&
        realDecoderSeekReanchorOk &&
        staleGenerationRejectedOk &&
        sinkResumedOk &&
        postSeekDrainOk &&
        sinkWriteAccountingOk &&
        checksumIdentityOk &&
        postSeekPlaybackHeadAdvancedOk &&
        transportCompletedOk &&
        threadOwnershipOk &&
        lifecycleDisposeOk;

    final allRequiredGatesPresent = missingGates.isEmpty;
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
        allRequiredGatesPresent &&
        allRequiredGatesTrue &&
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
          : rawMarker;
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
      } else if (!allRequiredGatesPresent) {
        finalLastError = 'missing_gate_${missingGates.first}';
        finalStatus = 'missing_gate';
      } else if (!allRequiredGatesTrue) {
        finalLastError = 'gate_failed';
        finalStatus = 'gate_failed';
      } else {
        finalLastError = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
        finalStatus = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      }
    }

    final finalLanes = <String, Object?>{
      'formatProbeOk': formatProbeOk,
      'preRollOk': preRollOk,
      'initialDrainOk': initialDrainOk,
      'seekQuiesceAccountingOk': seekQuiesceAccountingOk,
      'pauseCommandOk': pauseCommandOk,
      'sinkPausedOk': sinkPausedOk,
      'seekCommandOk': seekCommandOk,
      'sinkFlushAtSeekOk': sinkFlushAtSeekOk,
      'realDecoderSeekReanchorOk': realDecoderSeekReanchorOk,
      'staleGenerationRejectedOk': staleGenerationRejectedOk,
      'sinkResumedOk': sinkResumedOk,
      'postSeekDrainOk': postSeekDrainOk,
      'sinkWriteAccountingOk': sinkWriteAccountingOk,
      'checksumIdentityOk': checksumIdentityOk,
      'postSeekPlaybackHeadAdvancedOk': postSeekPlaybackHeadAdvancedOk,
      'transportCompletedOk': transportCompletedOk,
      'threadOwnershipOk': threadOwnershipOk,
      'lifecycleDisposeOk': lifecycleDisposeOk,
      'proofBoundaryOk': proofBoundaryOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{...parsedMetrics};

    return VGRealtimePlaybackPipelineSeekSmokeReport(
      pass: computedPass,
      status: finalStatus,
      marker: finalMarker,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: failureReason,
      details: details,
      formatProbeOk: formatProbeOk,
      preRollOk: preRollOk,
      initialDrainOk: initialDrainOk,
      seekQuiesceAccountingOk: seekQuiesceAccountingOk,
      pauseCommandOk: pauseCommandOk,
      sinkPausedOk: sinkPausedOk,
      seekCommandOk: seekCommandOk,
      sinkFlushAtSeekOk: sinkFlushAtSeekOk,
      realDecoderSeekReanchorOk: realDecoderSeekReanchorOk,
      staleGenerationRejectedOk: staleGenerationRejectedOk,
      sinkResumedOk: sinkResumedOk,
      postSeekDrainOk: postSeekDrainOk,
      sinkWriteAccountingOk: sinkWriteAccountingOk,
      checksumIdentityOk: checksumIdentityOk,
      postSeekPlaybackHeadAdvancedOk: postSeekPlaybackHeadAdvancedOk,
      transportCompletedOk: transportCompletedOk,
      threadOwnershipOk: threadOwnershipOk,
      lifecycleDisposeOk: lifecycleDisposeOk,
      proofBoundaryOk: proofBoundaryOk,
      canonical: canonical,
      lanes: Map<String, Object?>.unmodifiable(finalLanes),
      metrics: Map<String, Object?>.unmodifiable(finalMetrics),
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

  static VGRealtimePlaybackPipelineSeekSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      for (final k in requiredGateKeys) k: false,
      'proofBoundaryOk': false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGRealtimePlaybackPipelineSeekSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      nativeProofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      preRollOk: false,
      initialDrainOk: false,
      seekQuiesceAccountingOk: false,
      pauseCommandOk: false,
      sinkPausedOk: false,
      seekCommandOk: false,
      sinkFlushAtSeekOk: false,
      realDecoderSeekReanchorOk: false,
      staleGenerationRejectedOk: false,
      sinkResumedOk: false,
      postSeekDrainOk: false,
      sinkWriteAccountingOk: false,
      checksumIdentityOk: false,
      postSeekPlaybackHeadAdvancedOk: false,
      transportCompletedOk: false,
      threadOwnershipOk: false,
      lifecycleDisposeOk: false,
      proofBoundaryOk: false,
      canonical: false,
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
      raw: 'pass=false;status=fail;marker=$failMarkerConstant;reason=$reason',
    );
  }

  /// Invokes the Android True-DAG Phase 4 Realtime Playback Pipeline Seek
  /// diagnostic smoke harness.
  ///
  /// [sourcePath] path to a media file with an audio track.
  /// [maxDurationSec] window duration in seconds (default 3.0).
  /// [maxFramesPerMix] quantum mix size in frames (default 256).
  /// [baseVolume] AudioTrack non-zero gain (default 0.5).
  /// [deadlineMs] total deadline in milliseconds (default 30000).
  /// [seekTargetSec] target seek position in seconds (default 1.5).
  /// [preSeekHoldWindows] pre-seek hold window count (default 64).
  /// [timeout] optionally bounds the invocation (defaults to 35 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGRealtimePlaybackPipelineSeekSmokeReport>
  runRealtimePlaybackPipelineSeekSmoke({
    required String sourcePath,
    double maxDurationSec = 3.0,
    int maxFramesPerMix = 256,
    double baseVolume = 0.5,
    int deadlineMs = 30000,
    double seekTargetSec = 1.5,
    int preSeekHoldWindows = 64,
    Duration timeout = const Duration(seconds: 35),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName, <String, dynamic>{
        'sourcePath': sourcePath,
        'maxDurationSec': maxDurationSec,
        'maxFramesPerMix': maxFramesPerMix,
        'baseVolume': baseVolume,
        'deadlineMs': deadlineMs,
        'seekTargetSec': seekTargetSec,
        'preSeekHoldWindows': preSeekHoldWindows,
      });
      final raw = await future.timeout(timeout);
      return VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(raw);
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
  String toString() =>
      'VGRealtimePlaybackPipelineSeekSmokeReport(pass: $pass, status: $status, '
      'marker: $marker, isVerifiedPass: $isVerifiedPass, '
      'formatProbeOk: $formatProbeOk, preRollOk: $preRollOk, initialDrainOk: $initialDrainOk, '
      'seekQuiesceAccountingOk: $seekQuiesceAccountingOk, pauseCommandOk: $pauseCommandOk, '
      'sinkPausedOk: $sinkPausedOk, seekCommandOk: $seekCommandOk, sinkFlushAtSeekOk: $sinkFlushAtSeekOk, '
      'realDecoderSeekReanchorOk: $realDecoderSeekReanchorOk, staleGenerationRejectedOk: $staleGenerationRejectedOk, '
      'sinkResumedOk: $sinkResumedOk, postSeekDrainOk: $postSeekDrainOk, '
      'sinkWriteAccountingOk: $sinkWriteAccountingOk, checksumIdentityOk: $checksumIdentityOk, '
      'postSeekPlaybackHeadAdvancedOk: $postSeekPlaybackHeadAdvancedOk, transportCompletedOk: $transportCompletedOk, '
      'threadOwnershipOk: $threadOwnershipOk, lifecycleDisposeOk: $lifecycleDisposeOk, '
      'proofBoundaryOk: $proofBoundaryOk, canonical: $canonical, failureReason: $failureReason, '
      'lastError: $lastError)';
}
