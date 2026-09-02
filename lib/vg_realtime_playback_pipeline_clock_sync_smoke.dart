// vg_realtime_playback_pipeline_clock_sync_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-CLOCK-SYNCHRONIZATION (Y7):
// Android True-DAG Phase 4 realtime playback pipeline clock synchronization
// diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimePlaybackPipelineClockSyncSmoke` MethodChannel route.
// Diagnostic-only - validates real MediaExtractor / MediaCodec decode into
// the Y5a external ingest seam, native Y1 transport, non-zero-gain AudioTrack
// sink whose sink thread owns every AudioTrack call and presentation clock updates,
// coordinator-owned transport commands, presentation clock read-only downstream
// snapshots with monotonic published position, at most one poll per drain pass
// after the write returned, epoch opened after playing, per-epoch unsigned-32
// unwrap with one wrap tolerated and strict regression failing closed, continuity
// by base offset accumulation, getTimestamp false non-terminal with bounded
// extrapolation becoming stale after the horizon, and synthetic ERROR_DEAD_OBJECT
// epoch reset across two sequential scenarios (FORWARD_PLAYTHROUGH_CLOCK_SYNC,
// DEAD_OBJECT_CLOCK_EPOCH_RESET) preceded by a deterministic clock self-check.
//
// Required proof lanes (23 native gates + canonical):
//   formatProbeOk, preRollOk, preStartDrainEmptyOk, timestampPollCadenceOk,
//   presentationClockAnchoredOk, presentationClockMonotonicOk,
//   presentationClockExtrapolatedOk, presentationClockStaleBoundOk,
//   presentationClockEpochResetOk, snapshotProvenanceOk, clockNoFeedbackOk,
//   timestampFailureNonterminalOk, deadObjectInjectedOnceOk,
//   deadObjectOldTrackReleasedOk, deadObjectNewTrackInitVolumePlayOk,
//   deadObjectRemainderResumedOk, deadObjectNoDoubleCountOk,
//   sinkWriteAccountingOk, checksumIdentityOk, transportCompletedOk,
//   audioTrackLifecycleOk, threadOwnershipOk, proofBoundaryOk.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimePlaybackPipelineClockSyncSmokeReport.runRealtimePlaybackPipelineClockSyncSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGRealtimePlaybackPipelineClockSyncSmokeReport {
  const VGRealtimePlaybackPipelineClockSyncSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.gates,
    required this.canonical,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
    this.raw = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runRealtimePlaybackPipelineClockSyncSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_CLOCK_SYNC_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_CLOCK_SYNC_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_CLOCK_SYNC_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_CLOCK_SYNC_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'realtime_playback_pipeline_clock_sync_diagnostic_only_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_sink_thread_owns_audiotrack_gettimestamp_and_presentation_clock_updates_coordinator_owns_transport_commands_presentation_clock_read_only_downstream_any_thread_snapshots_monotonic_published_position_one_poll_per_drain_pass_after_write_epoch_opens_after_playing_epoch_model_audiotrack_instance_per_epoch_unsigned32_unwrap_one_wrap_tolerated_regression_fails_closed_continuity_by_base_offset_accumulation_gettimestamp_false_nonterminal_bounded_extrapolation_stale_after_horizon_no_fabricated_position_synthetic_dead_object_epoch_reset_only_no_seek_no_flush_no_av_sync_no_drift_correction_no_hal_output_latency_no_gettimestamp_availability_sla_no_pacing_no_write_feedback_no_drain_gating_no_checksum_feedback_no_underrun_handling_no_real_os_fault_forcing_no_seamless_hot_swap_no_product_no_editor_no_app_wiring_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_no_jni_changes';

  /// All required native gate keys that must be present and evaluate to true.
  static const List<String> requiredGateKeys = <String>[
    'formatProbeOk',
    'preRollOk',
    'preStartDrainEmptyOk',
    'timestampPollCadenceOk',
    'presentationClockAnchoredOk',
    'presentationClockMonotonicOk',
    'presentationClockExtrapolatedOk',
    'presentationClockStaleBoundOk',
    'presentationClockEpochResetOk',
    'snapshotProvenanceOk',
    'clockNoFeedbackOk',
    'timestampFailureNonterminalOk',
    'deadObjectInjectedOnceOk',
    'deadObjectOldTrackReleasedOk',
    'deadObjectNewTrackInitVolumePlayOk',
    'deadObjectRemainderResumedOk',
    'deadObjectNoDoubleCountOk',
    'sinkWriteAccountingOk',
    'checksumIdentityOk',
    'transportCompletedOk',
    'audioTrackLifecycleOk',
    'threadOwnershipOk',
    'proofBoundaryOk',
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

  /// Parsed required gates keyed by [requiredGateKeys].
  final Map<String, bool> gates;

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

  // ---- Gate getters -------------------------------------------------------

  bool gate(String key) => gates[key] ?? false;
  bool get formatProbeOk => gate('formatProbeOk');
  bool get preRollOk => gate('preRollOk');
  bool get preStartDrainEmptyOk => gate('preStartDrainEmptyOk');
  bool get timestampPollCadenceOk => gate('timestampPollCadenceOk');
  bool get presentationClockAnchoredOk => gate('presentationClockAnchoredOk');
  bool get presentationClockMonotonicOk => gate('presentationClockMonotonicOk');
  bool get presentationClockExtrapolatedOk =>
      gate('presentationClockExtrapolatedOk');
  bool get presentationClockStaleBoundOk =>
      gate('presentationClockStaleBoundOk');
  bool get presentationClockEpochResetOk =>
      gate('presentationClockEpochResetOk');
  bool get snapshotProvenanceOk => gate('snapshotProvenanceOk');
  bool get clockNoFeedbackOk => gate('clockNoFeedbackOk');
  bool get timestampFailureNonterminalOk =>
      gate('timestampFailureNonterminalOk');
  bool get deadObjectInjectedOnceOk => gate('deadObjectInjectedOnceOk');
  bool get deadObjectOldTrackReleasedOk => gate('deadObjectOldTrackReleasedOk');
  bool get deadObjectNewTrackInitVolumePlayOk =>
      gate('deadObjectNewTrackInitVolumePlayOk');
  bool get deadObjectRemainderResumedOk => gate('deadObjectRemainderResumedOk');
  bool get deadObjectNoDoubleCountOk => gate('deadObjectNoDoubleCountOk');
  bool get sinkWriteAccountingOk => gate('sinkWriteAccountingOk');
  bool get checksumIdentityOk => gate('checksumIdentityOk');
  bool get transportCompletedOk => gate('transportCompletedOk');
  bool get audioTrackLifecycleOk => gate('audioTrackLifecycleOk');
  bool get threadOwnershipOk => gate('threadOwnershipOk');
  bool get proofBoundaryOk => gate('proofBoundaryOk');

  /// Whether every required gate is true.
  bool get allRequiredGatesTrue => requiredGateKeys.every(gate);

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
  bool get isVerifiedPass =>
      pass == true &&
      status.trim().toLowerCase() == 'pass' &&
      hasPassMarker &&
      hasCanonicalProofBoundary &&
      failureReason.isEmpty &&
      allRequiredGatesTrue;

  static Map<String, bool> _allFalseGates() => <String, bool>{
    for (final k in requiredGateKeys) k: false,
  };

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealtimePlaybackPipelineClockSyncSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGRealtimePlaybackPipelineClockSyncSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        nativeProofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        gates: Map<String, bool>.unmodifiable(_allFalseGates()),
        canonical: false,
        lanes: const <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        metrics: const <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        lastError: 'native_result_not_a_map',
        raw:
            'pass=false;status=fail;marker=$failMarkerConstant;reason=native_result_not_a_map',
      );
    }

    final parsedLanes = <String, Object?>{};
    final lanesRaw = raw['lanes'];
    if (lanesRaw is Map) {
      for (final entry in lanesRaw.entries) {
        final k = entry.key?.toString();
        if (k != null) parsedLanes[k] = entry.value;
      }
    }
    final parsedMetrics = <String, Object?>{};
    final metricsRaw = raw['metrics'];
    if (metricsRaw is Map) {
      for (final entry in metricsRaw.entries) {
        final k = entry.key?.toString();
        if (k != null) parsedMetrics[k] = entry.value;
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
        if (lower == 'false' || lower == 'fail') return false;
      }
      return null;
    }

    bool parseBool(String key, [bool defaultValue = false]) =>
        parseBoolStrict(key) ?? defaultValue;

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
    final gates = <String, bool>{};
    for (final gateKey in requiredGateKeys) {
      final v = parseBoolStrict(gateKey);
      if (v == null) missingGates.add(gateKey);
      gates[gateKey] = v ?? false;
    }
    final canonical = parseBool('canonical', rawPass && missingGates.isEmpty);

    final hasValidProofBoundary =
        proofBoundary == proofBoundaryConstant &&
        (nativeProofBoundary.isEmpty ||
            nativeProofBoundary == proofBoundaryConstant);
    final hasValidPassMarker = rawMarker == passMarkerConstant;
    final allRequiredGatesTrue = gates.values.every((v) => v);
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
      ...gates,
      'canonical': canonical,
      ...parsedLanes,
    };

    return VGRealtimePlaybackPipelineClockSyncSmokeReport(
      pass: computedPass,
      status: finalStatus,
      marker: finalMarker,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: failureReason,
      details: details,
      gates: Map<String, bool>.unmodifiable(gates),
      canonical: canonical,
      lanes: Map<String, Object?>.unmodifiable(finalLanes),
      metrics: Map<String, Object?>.unmodifiable(parsedMetrics),
      lastError: finalLastError,
      raw: rawString,
    );
  }

  /// Serializes the report back to a map.
  Map<String, Object?> toMap() => <String, Object?>{
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

  Map<String, Object?> toJson() => toMap();

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static VGRealtimePlaybackPipelineClockSyncSmokeReport
  _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      for (final k in requiredGateKeys) k: false,
      'canonical': false,
    };
    return VGRealtimePlaybackPipelineClockSyncSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      nativeProofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      gates: Map<String, bool>.unmodifiable(_allFalseGates()),
      canonical: false,
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(<String, Object?>{
        'status': 'FAIL',
        'reason': reason,
        if (details.isNotEmpty) 'details': details,
      }),
      lastError: lastError,
      raw: 'pass=false;status=fail;marker=$failMarkerConstant;reason=$reason',
    );
  }

  /// Invokes the Android True-DAG Phase 4 Realtime Playback Pipeline
  /// Clock Synchronization diagnostic smoke harness.
  static Future<VGRealtimePlaybackPipelineClockSyncSmokeReport>
  runRealtimePlaybackPipelineClockSyncSmoke({
    required String sourcePath,
    double maxDurationSec = 3.0,
    int maxFramesPerMix = 256,
    double baseVolume = 0.5,
    int deadlineMs = 60000,
    int phaseFrames = 2048,
    int extrapolationHorizonMs = 250,
    Duration timeout = const Duration(seconds: 65),
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
        'phaseFrames': phaseFrames,
        'extrapolationHorizonMs': extrapolationHorizonMs,
      });
      final raw = await future.timeout(timeout);
      return VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(raw);
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
      'VGRealtimePlaybackPipelineClockSyncSmokeReport(pass: $pass, '
      'status: $status, marker: $marker, isVerifiedPass: $isVerifiedPass, '
      'gates: $gates, canonical: $canonical, failureReason: $failureReason, '
      'lastError: $lastError)';
}
