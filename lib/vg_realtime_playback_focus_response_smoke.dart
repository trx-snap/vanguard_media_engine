// vg_realtime_playback_focus_response_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-FOCUS-RESPONSE (Y4a): Android True-DAG Phase 4
// realtime playback audio focus and becoming noisy response diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimePlaybackFocusResponseSmoke` MethodChannel route.
// Diagnostic-only - validates the VanguardRealtimePlaybackFocusResponseSink Kotlin adapter
// driven by the authoritative VanguardRealtimePlaybackTransportStateMachine (Y1),
// one VanguardRealtimePlaybackAudioFocusController, and an android.media.AudioTrack MODE_STREAM sink
// across three sequential scenarios: EOS_COMPLETION, BECOMING_NOISY_TERMINAL, and PERMANENT_LOSS_TERMINAL.
//
// Honest non-claims (Proof Boundary):
// realtime_playback_focus_noisy_response_diagnostic_only_nonzero_gain_audiotrack_sink_base_gain_0_5_duck_gain_0_1_setvolume_telemetry_only_synthetic_pcm_from_y1_transport_no_mediacodec_no_mediaextractor_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_os_focus_arbitration_claim_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimePlaybackFocusResponseSmokeReport.runRealtimePlaybackFocusResponseSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGRealtimePlaybackFocusResponseSmokeReport {
  const VGRealtimePlaybackFocusResponseSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.focusGrantedOk,
    required this.noisyReceiverRegisteredOk,
    required this.baseGainSetOk,
    required this.duckAppliedOk,
    required this.duckRestoreOk,
    required this.transientPauseResumeOk,
    required this.becomingNoisyPauseOk,
    required this.permanentStopNoAutoResumeOk,
    required this.transportStoppedOk,
    required this.transportCompletedOk,
    required this.checksumIdentityOk,
    required this.sinkWriteAccountingOk,
    required this.audioTrackReleasedOk,
    required this.focusAbandonedOk,
    required this.receiverUnregisteredOk,
    required this.eventsDroppedZeroOk,
    required this.lifecycleOk,
    required this.eosScenarioPass,
    required this.noisyTerminalScenarioPass,
    required this.permanentTerminalScenarioPass,
    required this.allNativeLanesPass,
    required this.canonical,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
    this.raw = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runRealtimePlaybackFocusResponseSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'realtime_playback_focus_noisy_response_diagnostic_only_nonzero_gain_audiotrack_sink_base_gain_0_5_duck_gain_0_1_setvolume_telemetry_only_synthetic_pcm_from_y1_transport_no_mediacodec_no_mediaextractor_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_os_focus_arbitration_claim_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes';

  /// All required native gate keys that must be present and evaluate to true.
  static const List<String> requiredGateKeys = <String>[
    'focusGrantedOk',
    'noisyReceiverRegisteredOk',
    'baseGainSetOk',
    'duckAppliedOk',
    'duckRestoreOk',
    'transientPauseResumeOk',
    'becomingNoisyPauseOk',
    'permanentStopNoAutoResumeOk',
    'transportStoppedOk',
    'transportCompletedOk',
    'checksumIdentityOk',
    'sinkWriteAccountingOk',
    'audioTrackReleasedOk',
    'focusAbandonedOk',
    'receiverUnregisteredOk',
    'eventsDroppedZeroOk',
    'lifecycleOk',
    'eosScenarioPass',
    'noisyTerminalScenarioPass',
    'permanentTerminalScenarioPass',
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

  /// Whether audio focus request was granted across all scenarios.
  final bool focusGrantedOk;

  /// Whether becoming-noisy receiver was registered across all scenarios.
  final bool noisyReceiverRegisteredOk;

  /// Whether initial base gain was set successfully on the AudioTrack sink.
  final bool baseGainSetOk;

  /// Whether duck gain attenuation was applied upon transient loss with duck.
  final bool duckAppliedOk;

  /// Whether base gain was restored upon focus gain after ducking.
  final bool duckRestoreOk;

  /// Whether transient pause, hold, duplicate no-op, and gain resume succeeded.
  final bool transientPauseResumeOk;

  /// Whether becoming-noisy pause held frozen and prevented auto-resume.
  final bool becomingNoisyPauseOk;

  /// Whether permanent focus loss stopped transport and rejected subsequent gain.
  final bool permanentStopNoAutoResumeOk;

  /// Whether transport stopped properly in the permanent loss terminal scenario.
  final bool transportStoppedOk;

  /// Whether transport completed EOS in the normal EOS completion scenario.
  final bool transportCompletedOk;

  /// Whether sink checksum matched native session checksum across scenarios.
  final bool checksumIdentityOk;

  /// Whether frames read from transport equaled frames written to AudioTrack sink.
  final bool sinkWriteAccountingOk;

  /// Whether AudioTrack was released exactly once per scenario run.
  final bool audioTrackReleasedOk;

  /// Whether audio focus was abandoned exactly once per scenario run.
  final bool focusAbandonedOk;

  /// Whether noisy broadcast receiver was unregistered exactly once per scenario run.
  final bool receiverUnregisteredOk;

  /// Whether zero events were dropped from the controller queue across scenarios.
  final bool eventsDroppedZeroOk;

  /// Whether complete lifecycle teardown cleanly disposed all resources.
  final bool lifecycleOk;

  /// Whether the EOS completion scenario passed all assertions.
  final bool eosScenarioPass;

  /// Whether the becoming-noisy terminal scenario passed all assertions.
  final bool noisyTerminalScenarioPass;

  /// Whether the permanent loss terminal scenario passed all assertions.
  final bool permanentTerminalScenarioPass;

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
      focusGrantedOk &&
      noisyReceiverRegisteredOk &&
      baseGainSetOk &&
      duckAppliedOk &&
      duckRestoreOk &&
      transientPauseResumeOk &&
      becomingNoisyPauseOk &&
      permanentStopNoAutoResumeOk &&
      transportStoppedOk &&
      transportCompletedOk &&
      checksumIdentityOk &&
      sinkWriteAccountingOk &&
      audioTrackReleasedOk &&
      focusAbandonedOk &&
      receiverUnregisteredOk &&
      eventsDroppedZeroOk &&
      lifecycleOk &&
      eosScenarioPass &&
      noisyTerminalScenarioPass &&
      permanentTerminalScenarioPass &&
      allNativeLanesPass;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealtimePlaybackFocusResponseSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGRealtimePlaybackFocusResponseSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        nativeProofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        focusGrantedOk: false,
        noisyReceiverRegisteredOk: false,
        baseGainSetOk: false,
        duckAppliedOk: false,
        duckRestoreOk: false,
        transientPauseResumeOk: false,
        becomingNoisyPauseOk: false,
        permanentStopNoAutoResumeOk: false,
        transportStoppedOk: false,
        transportCompletedOk: false,
        checksumIdentityOk: false,
        sinkWriteAccountingOk: false,
        audioTrackReleasedOk: false,
        focusAbandonedOk: false,
        receiverUnregisteredOk: false,
        eventsDroppedZeroOk: false,
        lifecycleOk: false,
        eosScenarioPass: false,
        noisyTerminalScenarioPass: false,
        permanentTerminalScenarioPass: false,
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

    final focusGrantedOk = parseBool('focusGrantedOk');
    final noisyReceiverRegisteredOk = parseBool('noisyReceiverRegisteredOk');
    final baseGainSetOk = parseBool('baseGainSetOk');
    final duckAppliedOk = parseBool('duckAppliedOk');
    final duckRestoreOk = parseBool('duckRestoreOk');
    final transientPauseResumeOk = parseBool('transientPauseResumeOk');
    final becomingNoisyPauseOk = parseBool('becomingNoisyPauseOk');
    final permanentStopNoAutoResumeOk = parseBool(
      'permanentStopNoAutoResumeOk',
    );
    final transportStoppedOk = parseBool('transportStoppedOk');
    final transportCompletedOk = parseBool('transportCompletedOk');
    final checksumIdentityOk = parseBool('checksumIdentityOk');
    final sinkWriteAccountingOk = parseBool('sinkWriteAccountingOk');
    final audioTrackReleasedOk = parseBool('audioTrackReleasedOk');
    final focusAbandonedOk = parseBool('focusAbandonedOk');
    final receiverUnregisteredOk = parseBool('receiverUnregisteredOk');
    final eventsDroppedZeroOk = parseBool('eventsDroppedZeroOk');
    final lifecycleOk = parseBool('lifecycleOk');
    final eosScenarioPass = parseBool('eosScenarioPass');
    final noisyTerminalScenarioPass = parseBool('noisyTerminalScenarioPass');
    final permanentTerminalScenarioPass = parseBool(
      'permanentTerminalScenarioPass',
    );
    final allNativeLanesPass = parseBool('allNativeLanesPass');
    final canonical = parseBool('canonical', rawPass && missingGates.isEmpty);

    final hasValidProofBoundary =
        proofBoundary == proofBoundaryConstant &&
        (nativeProofBoundary.isEmpty ||
            nativeProofBoundary == proofBoundaryConstant);
    final hasValidPassMarker = rawMarker == passMarkerConstant;

    final allRequiredGatesTrue =
        focusGrantedOk &&
        noisyReceiverRegisteredOk &&
        baseGainSetOk &&
        duckAppliedOk &&
        duckRestoreOk &&
        transientPauseResumeOk &&
        becomingNoisyPauseOk &&
        permanentStopNoAutoResumeOk &&
        transportStoppedOk &&
        transportCompletedOk &&
        checksumIdentityOk &&
        sinkWriteAccountingOk &&
        audioTrackReleasedOk &&
        focusAbandonedOk &&
        receiverUnregisteredOk &&
        eventsDroppedZeroOk &&
        lifecycleOk &&
        eosScenarioPass &&
        noisyTerminalScenarioPass &&
        permanentTerminalScenarioPass &&
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
      'focusGrantedOk': focusGrantedOk,
      'noisyReceiverRegisteredOk': noisyReceiverRegisteredOk,
      'baseGainSetOk': baseGainSetOk,
      'duckAppliedOk': duckAppliedOk,
      'duckRestoreOk': duckRestoreOk,
      'transientPauseResumeOk': transientPauseResumeOk,
      'becomingNoisyPauseOk': becomingNoisyPauseOk,
      'permanentStopNoAutoResumeOk': permanentStopNoAutoResumeOk,
      'transportStoppedOk': transportStoppedOk,
      'transportCompletedOk': transportCompletedOk,
      'checksumIdentityOk': checksumIdentityOk,
      'sinkWriteAccountingOk': sinkWriteAccountingOk,
      'audioTrackReleasedOk': audioTrackReleasedOk,
      'focusAbandonedOk': focusAbandonedOk,
      'receiverUnregisteredOk': receiverUnregisteredOk,
      'eventsDroppedZeroOk': eventsDroppedZeroOk,
      'lifecycleOk': lifecycleOk,
      'eosScenarioPass': eosScenarioPass,
      'noisyTerminalScenarioPass': noisyTerminalScenarioPass,
      'permanentTerminalScenarioPass': permanentTerminalScenarioPass,
      'allNativeLanesPass': allNativeLanesPass,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{...parsedMetrics};

    return VGRealtimePlaybackFocusResponseSmokeReport(
      pass: computedPass,
      status: finalStatus,
      marker: finalMarker,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: failureReason,
      details: details,
      focusGrantedOk: focusGrantedOk,
      noisyReceiverRegisteredOk: noisyReceiverRegisteredOk,
      baseGainSetOk: baseGainSetOk,
      duckAppliedOk: duckAppliedOk,
      duckRestoreOk: duckRestoreOk,
      transientPauseResumeOk: transientPauseResumeOk,
      becomingNoisyPauseOk: becomingNoisyPauseOk,
      permanentStopNoAutoResumeOk: permanentStopNoAutoResumeOk,
      transportStoppedOk: transportStoppedOk,
      transportCompletedOk: transportCompletedOk,
      checksumIdentityOk: checksumIdentityOk,
      sinkWriteAccountingOk: sinkWriteAccountingOk,
      audioTrackReleasedOk: audioTrackReleasedOk,
      focusAbandonedOk: focusAbandonedOk,
      receiverUnregisteredOk: receiverUnregisteredOk,
      eventsDroppedZeroOk: eventsDroppedZeroOk,
      lifecycleOk: lifecycleOk,
      eosScenarioPass: eosScenarioPass,
      noisyTerminalScenarioPass: noisyTerminalScenarioPass,
      permanentTerminalScenarioPass: permanentTerminalScenarioPass,
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

  static VGRealtimePlaybackFocusResponseSmokeReport _makeErrorFallbackReport({
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
    return VGRealtimePlaybackFocusResponseSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      nativeProofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      focusGrantedOk: false,
      noisyReceiverRegisteredOk: false,
      baseGainSetOk: false,
      duckAppliedOk: false,
      duckRestoreOk: false,
      transientPauseResumeOk: false,
      becomingNoisyPauseOk: false,
      permanentStopNoAutoResumeOk: false,
      transportStoppedOk: false,
      transportCompletedOk: false,
      checksumIdentityOk: false,
      sinkWriteAccountingOk: false,
      audioTrackReleasedOk: false,
      focusAbandonedOk: false,
      receiverUnregisteredOk: false,
      eventsDroppedZeroOk: false,
      lifecycleOk: false,
      eosScenarioPass: false,
      noisyTerminalScenarioPass: false,
      permanentTerminalScenarioPass: false,
      allNativeLanesPass: false,
      canonical: false,
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
      raw: 'pass=false;status=fail;marker=$failMarkerConstant;reason=$reason',
    );
  }

  /// Invokes the Android True-DAG Phase 4 Realtime Playback Focus Response
  /// diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation (defaults to 25 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGRealtimePlaybackFocusResponseSmokeReport>
  runRealtimePlaybackFocusResponseSmoke({
    Duration timeout = const Duration(seconds: 25),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = await future.timeout(timeout);
      return VGRealtimePlaybackFocusResponseSmokeReport.fromMap(raw);
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
      'VGRealtimePlaybackFocusResponseSmokeReport(pass: $pass, status: $status, '
      'marker: $marker, isVerifiedPass: $isVerifiedPass, '
      'focusGrantedOk: $focusGrantedOk, noisyReceiverRegisteredOk: $noisyReceiverRegisteredOk, '
      'baseGainSetOk: $baseGainSetOk, duckAppliedOk: $duckAppliedOk, '
      'duckRestoreOk: $duckRestoreOk, transientPauseResumeOk: $transientPauseResumeOk, '
      'becomingNoisyPauseOk: $becomingNoisyPauseOk, permanentStopNoAutoResumeOk: $permanentStopNoAutoResumeOk, '
      'transportStoppedOk: $transportStoppedOk, transportCompletedOk: $transportCompletedOk, '
      'checksumIdentityOk: $checksumIdentityOk, sinkWriteAccountingOk: $sinkWriteAccountingOk, '
      'audioTrackReleasedOk: $audioTrackReleasedOk, focusAbandonedOk: $focusAbandonedOk, '
      'receiverUnregisteredOk: $receiverUnregisteredOk, eventsDroppedZeroOk: $eventsDroppedZeroOk, '
      'lifecycleOk: $lifecycleOk, eosScenarioPass: $eosScenarioPass, '
      'noisyTerminalScenarioPass: $noisyTerminalScenarioPass, '
      'permanentTerminalScenarioPass: $permanentTerminalScenarioPass, '
      'allNativeLanesPass: $allNativeLanesPass, canonical: $canonical, '
      'failureReason: $failureReason, lastError: $lastError)';
}
