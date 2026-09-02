// vg_realtime_playback_sink_fault_tolerance_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-SINK-FAULT-TOLERANCE (Y4b): Android True-DAG Phase 4
// realtime playback AudioTrack sink fault tolerance diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimePlaybackSinkFaultToleranceSmoke` MethodChannel route.
// Diagnostic-only - validates the VanguardRealtimePlaybackSinkFaultToleranceSink Kotlin adapter
// driven by the authoritative VanguardRealtimePlaybackTransportStateMachine (Y1),
// one VanguardRealtimePlaybackRoutingController, and an android.media.AudioTrack MODE_STREAM sink
// across two sequential scenarios: EOS_WITH_DEAD_OBJECT_RECOVERY and ROUTE_DISCONNECT_TERMINAL.
//
// Honest non-claims (Proof Boundary):
// realtime_playback_sink_fault_tolerance_diagnostic_only_nonzero_gain_audiotrack_sink_base_gain_0_5_synthetic_pcm_from_y1_transport_synthetic_dead_object_recovery_only_route_change_listener_handoff_and_fail_closed_pause_only_no_mediacodec_no_mediaextractor_no_presentation_clock_no_av_sync_no_os_route_arbitration_claim_no_real_os_dead_object_forcing_claim_no_seamless_hot_swap_claim_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimePlaybackSinkFaultToleranceSmokeReport.runRealtimePlaybackSinkFaultToleranceSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGRealtimePlaybackSinkFaultToleranceSmokeReport {
  const VGRealtimePlaybackSinkFaultToleranceSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.audioTrackInitOk,
    required this.baseGainSetOk,
    required this.routingListenerRegisteredOk,
    required this.routingListenerUnregisteredOk,
    required this.routeChangeObservationOk,
    required this.routeDisconnectFailClosedPauseOk,
    required this.deadObjectInjectedOnceOk,
    required this.deadObjectOldTrackReleasedOk,
    required this.deadObjectNewTrackStateInitializedOk,
    required this.deadObjectNewTrackVolumeSetOk,
    required this.deadObjectNewTrackPlayOk,
    required this.deadObjectRemainderResumedOk,
    required this.deadObjectNoDoubleCountOk,
    required this.transportCompletedOk,
    required this.transportStoppedOk,
    required this.checksumIdentityOk,
    required this.sinkWriteAccountingOk,
    required this.audioTrackReleasedOk,
    required this.eventsDroppedZeroOk,
    required this.lifecycleOk,
    required this.eosScenarioPass,
    required this.routeDisconnectTerminalScenarioPass,
    required this.allNativeLanesPass,
    required this.canonical,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
    this.raw = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runRealtimePlaybackSinkFaultToleranceSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'realtime_playback_sink_fault_tolerance_diagnostic_only_nonzero_gain_audiotrack_sink_base_gain_0_5_synthetic_pcm_from_y1_transport_synthetic_dead_object_recovery_only_route_change_listener_handoff_and_fail_closed_pause_only_no_mediacodec_no_mediaextractor_no_presentation_clock_no_av_sync_no_os_route_arbitration_claim_no_real_os_dead_object_forcing_claim_no_seamless_hot_swap_claim_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes';

  /// All required native gate keys that must be present and evaluate to true.
  static const List<String> requiredGateKeys = <String>[
    'audioTrackInitOk',
    'baseGainSetOk',
    'routingListenerRegisteredOk',
    'routingListenerUnregisteredOk',
    'routeChangeObservationOk',
    'routeDisconnectFailClosedPauseOk',
    'deadObjectInjectedOnceOk',
    'deadObjectOldTrackReleasedOk',
    'deadObjectNewTrackStateInitializedOk',
    'deadObjectNewTrackVolumeSetOk',
    'deadObjectNewTrackPlayOk',
    'deadObjectRemainderResumedOk',
    'deadObjectNoDoubleCountOk',
    'transportCompletedOk',
    'transportStoppedOk',
    'checksumIdentityOk',
    'sinkWriteAccountingOk',
    'audioTrackReleasedOk',
    'eventsDroppedZeroOk',
    'lifecycleOk',
    'eosScenarioPass',
    'routeDisconnectTerminalScenarioPass',
    'allNativeLanesPass',
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

  /// Whether AudioTrack initialization succeeded across all scenarios.
  final bool audioTrackInitOk;

  /// Whether initial base gain (0.5) was set successfully on the AudioTrack sink.
  final bool baseGainSetOk;

  /// Whether routing listener was registered across AudioTrack instances.
  final bool routingListenerRegisteredOk;

  /// Whether routing listener was unregistered upon track release/handoff.
  final bool routingListenerUnregisteredOk;

  /// Whether synthetic route change was observed cleanly on the run thread.
  final bool routeChangeObservationOk;

  /// Whether route disconnect triggered fail-closed pause without auto-resume.
  final bool routeDisconnectFailClosedPauseOk;

  /// Whether synthetic dead object was injected exactly once.
  final bool deadObjectInjectedOnceOk;

  /// Whether old AudioTrack was released once upon dead object recovery.
  final bool deadObjectOldTrackReleasedOk;

  /// Whether new AudioTrack reached STATE_INITIALIZED upon recreation.
  final bool deadObjectNewTrackStateInitializedOk;

  /// Whether new AudioTrack had base gain set upon recreation.
  final bool deadObjectNewTrackVolumeSetOk;

  /// Whether new AudioTrack play() transitioned to PLAYSTATE_PLAYING.
  final bool deadObjectNewTrackPlayOk;

  /// Whether in-flight buffer remainder was resumed on the new AudioTrack.
  final bool deadObjectRemainderResumedOk;

  /// Whether dead object recovery completed without double-counting or drops.
  final bool deadObjectNoDoubleCountOk;

  /// Whether transport completed EOS in the normal EOS recovery scenario.
  final bool transportCompletedOk;

  /// Whether transport stopped properly in the route disconnect scenario.
  final bool transportStoppedOk;

  /// Whether sink checksum matched native session checksum across scenarios.
  final bool checksumIdentityOk;

  /// Whether frames read from transport equaled frames written to AudioTrack sink.
  final bool sinkWriteAccountingOk;

  /// Whether all created AudioTrack instances were released properly.
  final bool audioTrackReleasedOk;

  /// Whether zero events were dropped from the controller queue across scenarios.
  final bool eventsDroppedZeroOk;

  /// Whether complete lifecycle teardown cleanly disposed all resources.
  final bool lifecycleOk;

  /// Whether the EOS with dead-object recovery scenario passed all assertions.
  final bool eosScenarioPass;

  /// Whether the route disconnect terminal scenario passed all assertions.
  final bool routeDisconnectTerminalScenarioPass;

  /// Native aggregate gate indicating all scenario lanes passed.
  final bool allNativeLanesPass;

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
      audioTrackInitOk &&
      baseGainSetOk &&
      routingListenerRegisteredOk &&
      routingListenerUnregisteredOk &&
      routeChangeObservationOk &&
      routeDisconnectFailClosedPauseOk &&
      deadObjectInjectedOnceOk &&
      deadObjectOldTrackReleasedOk &&
      deadObjectNewTrackStateInitializedOk &&
      deadObjectNewTrackVolumeSetOk &&
      deadObjectNewTrackPlayOk &&
      deadObjectRemainderResumedOk &&
      deadObjectNoDoubleCountOk &&
      transportCompletedOk &&
      transportStoppedOk &&
      checksumIdentityOk &&
      sinkWriteAccountingOk &&
      audioTrackReleasedOk &&
      eventsDroppedZeroOk &&
      lifecycleOk &&
      eosScenarioPass &&
      routeDisconnectTerminalScenarioPass &&
      allNativeLanesPass;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealtimePlaybackSinkFaultToleranceSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGRealtimePlaybackSinkFaultToleranceSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        nativeProofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        audioTrackInitOk: false,
        baseGainSetOk: false,
        routingListenerRegisteredOk: false,
        routingListenerUnregisteredOk: false,
        routeChangeObservationOk: false,
        routeDisconnectFailClosedPauseOk: false,
        deadObjectInjectedOnceOk: false,
        deadObjectOldTrackReleasedOk: false,
        deadObjectNewTrackStateInitializedOk: false,
        deadObjectNewTrackVolumeSetOk: false,
        deadObjectNewTrackPlayOk: false,
        deadObjectRemainderResumedOk: false,
        deadObjectNoDoubleCountOk: false,
        transportCompletedOk: false,
        transportStoppedOk: false,
        checksumIdentityOk: false,
        sinkWriteAccountingOk: false,
        audioTrackReleasedOk: false,
        eventsDroppedZeroOk: false,
        lifecycleOk: false,
        eosScenarioPass: false,
        routeDisconnectTerminalScenarioPass: false,
        allNativeLanesPass: false,
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

    final audioTrackInitOk = parseBool('audioTrackInitOk');
    final baseGainSetOk = parseBool('baseGainSetOk');
    final routingListenerRegisteredOk = parseBool(
      'routingListenerRegisteredOk',
    );
    final routingListenerUnregisteredOk = parseBool(
      'routingListenerUnregisteredOk',
    );
    final routeChangeObservationOk = parseBool('routeChangeObservationOk');
    final routeDisconnectFailClosedPauseOk = parseBool(
      'routeDisconnectFailClosedPauseOk',
    );
    final deadObjectInjectedOnceOk = parseBool('deadObjectInjectedOnceOk');
    final deadObjectOldTrackReleasedOk = parseBool(
      'deadObjectOldTrackReleasedOk',
    );
    final deadObjectNewTrackStateInitializedOk = parseBool(
      'deadObjectNewTrackStateInitializedOk',
    );
    final deadObjectNewTrackVolumeSetOk = parseBool(
      'deadObjectNewTrackVolumeSetOk',
    );
    final deadObjectNewTrackPlayOk = parseBool('deadObjectNewTrackPlayOk');
    final deadObjectRemainderResumedOk = parseBool(
      'deadObjectRemainderResumedOk',
    );
    final deadObjectNoDoubleCountOk = parseBool('deadObjectNoDoubleCountOk');
    final transportCompletedOk = parseBool('transportCompletedOk');
    final transportStoppedOk = parseBool('transportStoppedOk');
    final checksumIdentityOk = parseBool('checksumIdentityOk');
    final sinkWriteAccountingOk = parseBool('sinkWriteAccountingOk');
    final audioTrackReleasedOk = parseBool('audioTrackReleasedOk');
    final eventsDroppedZeroOk = parseBool('eventsDroppedZeroOk');
    final lifecycleOk = parseBool('lifecycleOk');
    final eosScenarioPass = parseBool('eosScenarioPass');
    final routeDisconnectTerminalScenarioPass = parseBool(
      'routeDisconnectTerminalScenarioPass',
    );
    final allNativeLanesPass = parseBool('allNativeLanesPass');
    final canonical = parseBool('canonical', rawPass && missingGates.isEmpty);

    final hasValidProofBoundary =
        proofBoundary == proofBoundaryConstant &&
        (nativeProofBoundary.isEmpty ||
            nativeProofBoundary == proofBoundaryConstant);
    final hasValidPassMarker = rawMarker == passMarkerConstant;

    final allRequiredGatesTrue =
        audioTrackInitOk &&
        baseGainSetOk &&
        routingListenerRegisteredOk &&
        routingListenerUnregisteredOk &&
        routeChangeObservationOk &&
        routeDisconnectFailClosedPauseOk &&
        deadObjectInjectedOnceOk &&
        deadObjectOldTrackReleasedOk &&
        deadObjectNewTrackStateInitializedOk &&
        deadObjectNewTrackVolumeSetOk &&
        deadObjectNewTrackPlayOk &&
        deadObjectRemainderResumedOk &&
        deadObjectNoDoubleCountOk &&
        transportCompletedOk &&
        transportStoppedOk &&
        checksumIdentityOk &&
        sinkWriteAccountingOk &&
        audioTrackReleasedOk &&
        eventsDroppedZeroOk &&
        lifecycleOk &&
        eosScenarioPass &&
        routeDisconnectTerminalScenarioPass &&
        allNativeLanesPass;

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
      'audioTrackInitOk': audioTrackInitOk,
      'baseGainSetOk': baseGainSetOk,
      'routingListenerRegisteredOk': routingListenerRegisteredOk,
      'routingListenerUnregisteredOk': routingListenerUnregisteredOk,
      'routeChangeObservationOk': routeChangeObservationOk,
      'routeDisconnectFailClosedPauseOk': routeDisconnectFailClosedPauseOk,
      'deadObjectInjectedOnceOk': deadObjectInjectedOnceOk,
      'deadObjectOldTrackReleasedOk': deadObjectOldTrackReleasedOk,
      'deadObjectNewTrackStateInitializedOk':
          deadObjectNewTrackStateInitializedOk,
      'deadObjectNewTrackVolumeSetOk': deadObjectNewTrackVolumeSetOk,
      'deadObjectNewTrackPlayOk': deadObjectNewTrackPlayOk,
      'deadObjectRemainderResumedOk': deadObjectRemainderResumedOk,
      'deadObjectNoDoubleCountOk': deadObjectNoDoubleCountOk,
      'transportCompletedOk': transportCompletedOk,
      'transportStoppedOk': transportStoppedOk,
      'checksumIdentityOk': checksumIdentityOk,
      'sinkWriteAccountingOk': sinkWriteAccountingOk,
      'audioTrackReleasedOk': audioTrackReleasedOk,
      'eventsDroppedZeroOk': eventsDroppedZeroOk,
      'lifecycleOk': lifecycleOk,
      'eosScenarioPass': eosScenarioPass,
      'routeDisconnectTerminalScenarioPass':
          routeDisconnectTerminalScenarioPass,
      'allNativeLanesPass': allNativeLanesPass,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{...parsedMetrics};

    return VGRealtimePlaybackSinkFaultToleranceSmokeReport(
      pass: computedPass,
      status: finalStatus,
      marker: finalMarker,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: failureReason,
      details: details,
      audioTrackInitOk: audioTrackInitOk,
      baseGainSetOk: baseGainSetOk,
      routingListenerRegisteredOk: routingListenerRegisteredOk,
      routingListenerUnregisteredOk: routingListenerUnregisteredOk,
      routeChangeObservationOk: routeChangeObservationOk,
      routeDisconnectFailClosedPauseOk: routeDisconnectFailClosedPauseOk,
      deadObjectInjectedOnceOk: deadObjectInjectedOnceOk,
      deadObjectOldTrackReleasedOk: deadObjectOldTrackReleasedOk,
      deadObjectNewTrackStateInitializedOk:
          deadObjectNewTrackStateInitializedOk,
      deadObjectNewTrackVolumeSetOk: deadObjectNewTrackVolumeSetOk,
      deadObjectNewTrackPlayOk: deadObjectNewTrackPlayOk,
      deadObjectRemainderResumedOk: deadObjectRemainderResumedOk,
      deadObjectNoDoubleCountOk: deadObjectNoDoubleCountOk,
      transportCompletedOk: transportCompletedOk,
      transportStoppedOk: transportStoppedOk,
      checksumIdentityOk: checksumIdentityOk,
      sinkWriteAccountingOk: sinkWriteAccountingOk,
      audioTrackReleasedOk: audioTrackReleasedOk,
      eventsDroppedZeroOk: eventsDroppedZeroOk,
      lifecycleOk: lifecycleOk,
      eosScenarioPass: eosScenarioPass,
      routeDisconnectTerminalScenarioPass: routeDisconnectTerminalScenarioPass,
      allNativeLanesPass: allNativeLanesPass,
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

  static VGRealtimePlaybackSinkFaultToleranceSmokeReport
  _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      for (final k in requiredGateKeys) k: false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGRealtimePlaybackSinkFaultToleranceSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      nativeProofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      audioTrackInitOk: false,
      baseGainSetOk: false,
      routingListenerRegisteredOk: false,
      routingListenerUnregisteredOk: false,
      routeChangeObservationOk: false,
      routeDisconnectFailClosedPauseOk: false,
      deadObjectInjectedOnceOk: false,
      deadObjectOldTrackReleasedOk: false,
      deadObjectNewTrackStateInitializedOk: false,
      deadObjectNewTrackVolumeSetOk: false,
      deadObjectNewTrackPlayOk: false,
      deadObjectRemainderResumedOk: false,
      deadObjectNoDoubleCountOk: false,
      transportCompletedOk: false,
      transportStoppedOk: false,
      checksumIdentityOk: false,
      sinkWriteAccountingOk: false,
      audioTrackReleasedOk: false,
      eventsDroppedZeroOk: false,
      lifecycleOk: false,
      eosScenarioPass: false,
      routeDisconnectTerminalScenarioPass: false,
      allNativeLanesPass: false,
      canonical: false,
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
      raw: 'pass=false;status=fail;marker=$failMarkerConstant;reason=$reason',
    );
  }

  /// Invokes the Android True-DAG Phase 4 Realtime Playback Sink Fault Tolerance
  /// diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation (defaults to 25 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGRealtimePlaybackSinkFaultToleranceSmokeReport>
  runRealtimePlaybackSinkFaultToleranceSmoke({
    Duration timeout = const Duration(seconds: 25),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = await future.timeout(timeout);
      return VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(raw);
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
      'VGRealtimePlaybackSinkFaultToleranceSmokeReport(pass: $pass, status: $status, '
      'marker: $marker, isVerifiedPass: $isVerifiedPass, '
      'audioTrackInitOk: $audioTrackInitOk, baseGainSetOk: $baseGainSetOk, '
      'routingListenerRegisteredOk: $routingListenerRegisteredOk, '
      'routingListenerUnregisteredOk: $routingListenerUnregisteredOk, '
      'routeChangeObservationOk: $routeChangeObservationOk, '
      'routeDisconnectFailClosedPauseOk: $routeDisconnectFailClosedPauseOk, '
      'deadObjectInjectedOnceOk: $deadObjectInjectedOnceOk, '
      'deadObjectOldTrackReleasedOk: $deadObjectOldTrackReleasedOk, '
      'deadObjectNewTrackStateInitializedOk: $deadObjectNewTrackStateInitializedOk, '
      'deadObjectNewTrackVolumeSetOk: $deadObjectNewTrackVolumeSetOk, '
      'deadObjectNewTrackPlayOk: $deadObjectNewTrackPlayOk, '
      'deadObjectRemainderResumedOk: $deadObjectRemainderResumedOk, '
      'deadObjectNoDoubleCountOk: $deadObjectNoDoubleCountOk, '
      'transportCompletedOk: $transportCompletedOk, '
      'transportStoppedOk: $transportStoppedOk, '
      'checksumIdentityOk: $checksumIdentityOk, '
      'sinkWriteAccountingOk: $sinkWriteAccountingOk, '
      'audioTrackReleasedOk: $audioTrackReleasedOk, '
      'eventsDroppedZeroOk: $eventsDroppedZeroOk, '
      'lifecycleOk: $lifecycleOk, eosScenarioPass: $eosScenarioPass, '
      'routeDisconnectTerminalScenarioPass: $routeDisconnectTerminalScenarioPass, '
      'allNativeLanesPass: $allNativeLanesPass, canonical: $canonical, '
      'failureReason: $failureReason, lastError: $lastError)';
}
