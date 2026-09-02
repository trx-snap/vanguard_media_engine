// vg_realtime_playback_pipeline_sink_fault_tolerance_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SINK-FAULT-TOLERANCE (Y6e):
// Android True-DAG Phase 4 realtime playback pipeline sink fault tolerance
// diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimePlaybackPipelineSinkFaultToleranceSmoke` MethodChannel route.
// Diagnostic-only - validates real MediaExtractor / MediaCodec decode into
// the Y5a external ingest seam, native Y1 transport and a non-zero-gain
// AudioTrack sink whose sink thread owns every AudioTrack call, applies
// synthetic routing events and recovers exactly one synthetic
// ERROR_DEAD_OBJECT across two scenarios (EOS_WITH_DEAD_OBJECT_RECOVERY,
// ROUTE_DISCONNECT_TERMINAL).
//
// Required proof lanes (22 native gates + canonical):
//   formatProbeOk, preRollOk, routingListenerRegisteredOk,
//   preStartDrainEmptyOk, routeChangeObservationOk,
//   deadObjectInjectedOnceOk, deadObjectOldTrackReleasedOk,
//   deadObjectNewTrackStateInitializedOk, deadObjectNewTrackVolumeSetOk,
//   deadObjectNewTrackPlayOk, deadObjectRemainderResumedOk,
//   deadObjectNoDoubleCountOk, routeDisconnectFailClosedPauseOk,
//   routeDisconnectHoldFrozenOk, sinkWriteAccountingOk, checksumIdentityOk,
//   transportCompletedOk, transportStoppedOk, routingLifecycleOk,
//   audioTrackLifecycleOk, threadOwnershipOk, proofBoundaryOk.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.runRealtimePlaybackPipelineSinkFaultToleranceSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport {
  const VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport({
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
  static const String methodName =
      'runRealtimePlaybackPipelineSinkFaultToleranceSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SINK_FAULT_TOLERANCE_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SINK_FAULT_TOLERANCE_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SINK_FAULT_TOLERANCE_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SINK_FAULT_TOLERANCE_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'realtime_playback_pipeline_sink_fault_tolerance_diagnostic_only_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_synthetic_dead_object_injection_only_synthetic_route_disconnect_only_route_change_listener_handoff_sink_thread_owns_audiotrack_coordinator_owns_transport_commands_no_real_os_fault_forcing_no_seamless_hot_swap_no_presentation_clock_no_av_sync_no_latency_no_glitch_no_acoustic_no_loudness_no_snr_no_focus_no_noisy_no_seek_no_resample_no_downmix_no_product_no_editor_no_app_wiring_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_changes';

  /// All required native gate keys that must be present and evaluate to true.
  static const List<String> requiredGateKeys = <String>[
    'formatProbeOk',
    'preRollOk',
    'routingListenerRegisteredOk',
    'preStartDrainEmptyOk',
    'routeChangeObservationOk',
    'deadObjectInjectedOnceOk',
    'deadObjectOldTrackReleasedOk',
    'deadObjectNewTrackStateInitializedOk',
    'deadObjectNewTrackVolumeSetOk',
    'deadObjectNewTrackPlayOk',
    'deadObjectRemainderResumedOk',
    'deadObjectNoDoubleCountOk',
    'routeDisconnectFailClosedPauseOk',
    'routeDisconnectHoldFrozenOk',
    'sinkWriteAccountingOk',
    'checksumIdentityOk',
    'transportCompletedOk',
    'transportStoppedOk',
    'routingLifecycleOk',
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
  bool get routingListenerRegisteredOk => gate('routingListenerRegisteredOk');
  bool get preStartDrainEmptyOk => gate('preStartDrainEmptyOk');
  bool get routeChangeObservationOk => gate('routeChangeObservationOk');
  bool get deadObjectInjectedOnceOk => gate('deadObjectInjectedOnceOk');
  bool get deadObjectOldTrackReleasedOk => gate('deadObjectOldTrackReleasedOk');
  bool get deadObjectNewTrackStateInitializedOk =>
      gate('deadObjectNewTrackStateInitializedOk');
  bool get deadObjectNewTrackVolumeSetOk =>
      gate('deadObjectNewTrackVolumeSetOk');
  bool get deadObjectNewTrackPlayOk => gate('deadObjectNewTrackPlayOk');
  bool get deadObjectRemainderResumedOk => gate('deadObjectRemainderResumedOk');
  bool get deadObjectNoDoubleCountOk => gate('deadObjectNoDoubleCountOk');
  bool get routeDisconnectFailClosedPauseOk =>
      gate('routeDisconnectFailClosedPauseOk');
  bool get routeDisconnectHoldFrozenOk => gate('routeDisconnectHoldFrozenOk');
  bool get sinkWriteAccountingOk => gate('sinkWriteAccountingOk');
  bool get checksumIdentityOk => gate('checksumIdentityOk');
  bool get transportCompletedOk => gate('transportCompletedOk');
  bool get transportStoppedOk => gate('transportStoppedOk');
  bool get routingLifecycleOk => gate('routingLifecycleOk');
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
  static VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport fromMap(
    Object? raw,
  ) {
    if (raw is! Map) {
      return VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport(
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

    return VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport(
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

  static VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
  _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      for (final k in requiredGateKeys) k: false,
      'canonical': false,
    };
    return VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport(
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

  /// Invokes the Android True-DAG Phase 4 Realtime Playback Pipeline Sink
  /// Fault Tolerance diagnostic smoke harness.
  static Future<VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport>
  runRealtimePlaybackPipelineSinkFaultToleranceSmoke({
    required String sourcePath,
    double maxDurationSec = 3.0,
    int maxFramesPerMix = 256,
    double baseVolume = 0.5,
    int deadlineMs = 60000,
    int pauseHoldMs = 150,
    int phaseFrames = 2048,
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
        'pauseHoldMs': pauseHoldMs,
        'phaseFrames': phaseFrames,
      });
      final raw = await future.timeout(timeout);
      return VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap(
        raw,
      );
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
      'VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport(pass: $pass, '
      'status: $status, marker: $marker, isVerifiedPass: $isVerifiedPass, '
      'gates: $gates, canonical: $canonical, failureReason: $failureReason, '
      'lastError: $lastError)';
}
