// vg_realtime_playback_transport_core_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE (Y1): Android True-DAG Phase 4
// realtime playback transport core diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimePlaybackTransportCoreSmoke` MethodChannel route.
// Diagnostic-only - validates the native worker-owned steady_clock timebase,
// N (1..8) node-owned synthetic PCM16 source tracks, Kotlin transport state machine,
// track admission, partial EOS tail drain, reentrant playback sequence, paused seek,
// wrong-owner direct native probe, native registry capacity, and destroy idempotence.
//
// Honest non-claims (Proof Boundary):
// synthetic_pcm_only, no_audiotrack, no_mediacodec, no_mediaextractor,
// no_audiomanager, no_audible_output, no_product_editor_app_wiring, no_ios.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimePlaybackTransportCoreSmokeReport.runRealtimePlaybackTransportCoreSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGRealtimePlaybackTransportCoreSmokeReport {
  const VGRealtimePlaybackTransportCoreSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.trackAdmissionOk,
    required this.partialEosTailOk,
    required this.reentrantSequenceOk,
    required this.pausedSeekStaysPausedOk,
    required this.wrongOwnerDirectProbeOk,
    required this.registryCapacityOk,
    required this.destroyIdempotenceOk,
    required this.proofBoundaryOk,
    required this.canonical,
    required this.trackAdmission1Ok,
    required this.trackAdmission2Ok,
    required this.trackAdmission8Ok,
    required this.trackAdmission9RejectedOk,
    required this.partialEosTailRenderedFrames,
    required this.partialEosTailPushedFrames,
    required this.partialEosTailDrainedFrames,
    required this.partialEosTailPushedChecksumHex,
    required this.partialEosTailDrainedChecksumHex,
    required this.reentrantHoldDispatchUnchangedOk,
    required this.reentrantHoldPushedUnchangedOk,
    required this.reentrantForwardSeekNonQuiescentOk,
    required this.reentrantSeekForwardOk,
    required this.reentrantSeekBackwardOk,
    required this.reentrantRestartAndEosOk,
    required this.pausedSeekStayedPaused,
    required this.wrongOwnerStatus,
    required this.wrongOwnerFlag,
    required this.registryCapacityCount,
    required this.registryFifthFailedOk,
    required this.firstDestroyStatus,
    required this.firstDestroyWorkerJoined,
    required this.firstDestroyWorkerExited,
    required this.nativeSecondDestroyStatus,
    required this.wrapperSecondDestroyStatus,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runRealtimePlaybackTransportCoreSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'synthetic_pcm_only, no_audiotrack, no_mediacodec, no_mediaextractor, '
      'no_audiomanager, no_audible_output, no_product_editor_app_wiring, no_ios';

  /// All required native lane keys that must be present and reported.
  static const List<String> requiredNativeLaneKeys = <String>[
    'trackAdmissionOk',
    'partialEosTailOk',
    'reentrantSequenceOk',
    'pausedSeekStaysPausedOk',
    'wrongOwnerDirectProbeOk',
    'registryCapacityOk',
    'destroyIdempotenceOk',
    'proofBoundaryOk',
    'reentrantForwardSeekNonQuiescentOk',
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

  // ---- Lanes --------------------------------------------------------------

  /// Whether track admission passed for N=1, 2, 8 and failed closed for N=9.
  final bool trackAdmissionOk;

  /// Whether partial EOS tail frames drained with exact checksum identity and completion.
  final bool partialEosTailOk;

  /// Whether reentrant sequence (load, prepare, start, pause, hold, resume, seek, stop, restart, EOS) succeeded.
  final bool reentrantSequenceOk;

  /// Whether paused seek preserved the PAUSED state.
  final bool pausedSeekStaysPausedOk;

  /// Whether direct wrong-owner native probe reported wrong_owner_thread with no mutation.
  final bool wrongOwnerDirectProbeOk;

  /// Whether native registry capacity limit (4 live sessions, 5th rejected) succeeded.
  final bool registryCapacityOk;

  /// Whether destroy idempotence and distinct second-call statuses succeeded.
  final bool destroyIdempotenceOk;

  /// Whether proof boundary matches byte-identically.
  final bool proofBoundaryOk;

  /// Canonical pass indicator.
  final bool canonical;

  // ---- Metrics ------------------------------------------------------------

  final bool trackAdmission1Ok;
  final bool trackAdmission2Ok;
  final bool trackAdmission8Ok;
  final bool trackAdmission9RejectedOk;

  final int partialEosTailRenderedFrames;
  final int partialEosTailPushedFrames;
  final int partialEosTailDrainedFrames;
  final String partialEosTailPushedChecksumHex;
  final String partialEosTailDrainedChecksumHex;

  final bool reentrantHoldDispatchUnchangedOk;
  final bool reentrantHoldPushedUnchangedOk;
  final bool reentrantForwardSeekNonQuiescentOk;
  final bool reentrantSeekForwardOk;
  final bool reentrantSeekBackwardOk;
  final bool reentrantRestartAndEosOk;

  final bool pausedSeekStayedPaused;

  final String wrongOwnerStatus;
  final bool wrongOwnerFlag;

  final int registryCapacityCount;
  final bool registryFifthFailedOk;

  final String firstDestroyStatus;
  final bool firstDestroyWorkerJoined;
  final bool firstDestroyWorkerExited;
  final String nativeSecondDestroyStatus;
  final String wrapperSecondDestroyStatus;

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

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

  /// Whether all native diagnostic lanes passed according to the contract.
  bool get allNativeLanesPass {
    if (!pass) return false;
    if (status.toLowerCase() != 'pass') return false;
    if (!hasCanonicalProofBoundary) return false;
    if (!hasPassMarker) return false;
    if (!trackAdmissionOk) return false;
    if (!partialEosTailOk) return false;
    if (!reentrantSequenceOk) return false;
    if (!pausedSeekStaysPausedOk) return false;
    if (!wrongOwnerDirectProbeOk) return false;
    if (!registryCapacityOk) return false;
    if (!destroyIdempotenceOk) return false;
    if (!proofBoundaryOk) return false;
    if (!reentrantForwardSeekNonQuiescentOk) return false;
    if (!canonical) return false;
    if (lastError.isNotEmpty && lastError != 'none' && lastError != 'null') {
      return false;
    }
    return true;
  }

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealtimePlaybackTransportCoreSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGRealtimePlaybackTransportCoreSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        nativeProofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        trackAdmissionOk: false,
        partialEosTailOk: false,
        reentrantSequenceOk: false,
        pausedSeekStaysPausedOk: false,
        wrongOwnerDirectProbeOk: false,
        registryCapacityOk: false,
        destroyIdempotenceOk: false,
        proofBoundaryOk: false,
        canonical: false,
        trackAdmission1Ok: false,
        trackAdmission2Ok: false,
        trackAdmission8Ok: false,
        trackAdmission9RejectedOk: false,
        partialEosTailRenderedFrames: 0,
        partialEosTailPushedFrames: 0,
        partialEosTailDrainedFrames: 0,
        partialEosTailPushedChecksumHex: '',
        partialEosTailDrainedChecksumHex: '',
        reentrantHoldDispatchUnchangedOk: false,
        reentrantHoldPushedUnchangedOk: false,
        reentrantForwardSeekNonQuiescentOk: false,
        reentrantSeekForwardOk: false,
        reentrantSeekBackwardOk: false,
        reentrantRestartAndEosOk: false,
        pausedSeekStayedPaused: false,
        wrongOwnerStatus: '',
        wrongOwnerFlag: false,
        registryCapacityCount: 0,
        registryFifthFailedOk: false,
        firstDestroyStatus: '',
        firstDestroyWorkerJoined: false,
        firstDestroyWorkerExited: false,
        nativeSecondDestroyStatus: '',
        wrapperSecondDestroyStatus: '',
        lanes: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        lastError: 'native_result_not_a_map',
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

    int? parseIntStrict(String key) {
      final v = parsedMetrics[key] ?? raw[key] ?? parsedLanes[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    int parseInt(String key, [int defaultValue = 0]) {
      return parseIntStrict(key) ?? defaultValue;
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

    final missingLanes = <String>[];
    for (final laneKey in requiredNativeLaneKeys) {
      if (parseBoolStrict(laneKey) == null) {
        missingLanes.add(laneKey);
      }
    }

    final trackAdmissionOk = parseBool('trackAdmissionOk');
    final partialEosTailOk = parseBool('partialEosTailOk');
    final reentrantSequenceOk = parseBool('reentrantSequenceOk');
    final pausedSeekStaysPausedOk = parseBool('pausedSeekStaysPausedOk');
    final wrongOwnerDirectProbeOk = parseBool('wrongOwnerDirectProbeOk');
    final registryCapacityOk = parseBool('registryCapacityOk');
    final destroyIdempotenceOk = parseBool('destroyIdempotenceOk');
    final proofBoundaryOk = parseBool('proofBoundaryOk');
    final canonical = parseBool('canonical', rawPass && missingLanes.isEmpty);

    final trackAdmission1Ok = parseBool('trackAdmission1Ok');
    final trackAdmission2Ok = parseBool('trackAdmission2Ok');
    final trackAdmission8Ok = parseBool('trackAdmission8Ok');
    final trackAdmission9RejectedOk = parseBool('trackAdmission9RejectedOk');

    final partialEosTailRenderedFrames = parseInt(
      'partialEosTailRenderedFrames',
    );
    final partialEosTailPushedFrames = parseInt('partialEosTailPushedFrames');
    final partialEosTailDrainedFrames = parseInt('partialEosTailDrainedFrames');
    final partialEosTailPushedChecksumHex = parseString(
      'partialEosTailPushedChecksumHex',
    );
    final partialEosTailDrainedChecksumHex = parseString(
      'partialEosTailDrainedChecksumHex',
    );

    final reentrantHoldDispatchUnchangedOk = parseBool(
      'reentrantHoldDispatchUnchangedOk',
    );
    final reentrantHoldPushedUnchangedOk = parseBool(
      'reentrantHoldPushedUnchangedOk',
    );
    final reentrantForwardSeekNonQuiescentOk = parseBool(
      'reentrantForwardSeekNonQuiescentOk',
    );
    final reentrantSeekForwardOk = parseBool('reentrantSeekForwardOk');
    final reentrantSeekBackwardOk = parseBool('reentrantSeekBackwardOk');
    final reentrantRestartAndEosOk = parseBool('reentrantRestartAndEosOk');

    final pausedSeekStayedPaused = parseBool('pausedSeekStayedPaused');

    final wrongOwnerStatus = parseString('wrongOwnerStatus');
    final wrongOwnerFlag = parseBool('wrongOwnerFlag');

    final registryCapacityCount = parseInt('registryCapacityCount');
    final registryFifthFailedOk = parseBool('registryFifthFailedOk');

    final firstDestroyStatus = parseString('firstDestroyStatus');
    final firstDestroyWorkerJoined = parseBool('firstDestroyWorkerJoined');
    final firstDestroyWorkerExited = parseBool('firstDestroyWorkerExited');
    final nativeSecondDestroyStatus = parseString('nativeSecondDestroyStatus');
    final wrapperSecondDestroyStatus = parseString(
      'wrapperSecondDestroyStatus',
    );

    final hasValidProofBoundary =
        proofBoundary == proofBoundaryConstant &&
        (nativeProofBoundary.isEmpty ||
            nativeProofBoundary == proofBoundaryConstant);
    final hasValidPassMarker = rawMarker == passMarkerConstant;

    final allRequiredLanesTrue =
        trackAdmissionOk &&
        partialEosTailOk &&
        reentrantSequenceOk &&
        pausedSeekStaysPausedOk &&
        wrongOwnerDirectProbeOk &&
        registryCapacityOk &&
        destroyIdempotenceOk &&
        proofBoundaryOk &&
        reentrantForwardSeekNonQuiescentOk &&
        canonical;

    final allRequiredLanesPresent = missingLanes.isEmpty;

    final explicitLastError = parseString('lastError');
    final hasNoLastError =
        explicitLastError.isEmpty ||
        explicitLastError == 'none' ||
        explicitLastError == 'null';
    final hasNoFailureReason = failureReason.isEmpty;

    final pass =
        rawPass &&
        rawStatus.toLowerCase() == 'pass' &&
        hasValidPassMarker &&
        hasValidProofBoundary &&
        allRequiredLanesPresent &&
        allRequiredLanesTrue &&
        hasNoLastError &&
        hasNoFailureReason;

    final String status;
    final String marker;
    final String lastError;

    if (pass) {
      status = rawStatus;
      marker = passMarkerConstant;
      lastError = '';
    } else {
      marker = (rawMarker == passMarkerConstant)
          ? failMarkerConstant
          : rawMarker;
      if (failureReason.isNotEmpty) {
        lastError = failureReason;
        status = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      } else if (!hasNoLastError) {
        lastError = explicitLastError;
        status = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      } else if (!hasValidProofBoundary) {
        lastError = 'proof_boundary_mismatch';
        status = 'proof_boundary_mismatch';
      } else if (!hasValidPassMarker) {
        lastError = 'marker_mismatch';
        status = 'marker_mismatch';
      } else if (!allRequiredLanesPresent) {
        lastError = 'missing_lane_${missingLanes.first}';
        status = 'missing_lane';
      } else if (!allRequiredLanesTrue) {
        lastError = 'lane_failed';
        status = 'lane_failed';
      } else {
        lastError = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
        status = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      }
    }

    final finalLanes = <String, Object?>{
      'trackAdmissionOk': trackAdmissionOk,
      'partialEosTailOk': partialEosTailOk,
      'reentrantSequenceOk': reentrantSequenceOk,
      'pausedSeekStaysPausedOk': pausedSeekStaysPausedOk,
      'wrongOwnerDirectProbeOk': wrongOwnerDirectProbeOk,
      'registryCapacityOk': registryCapacityOk,
      'destroyIdempotenceOk': destroyIdempotenceOk,
      'proofBoundaryOk': proofBoundaryOk,
      'reentrantForwardSeekNonQuiescentOk': reentrantForwardSeekNonQuiescentOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{
      'trackAdmission1Ok': trackAdmission1Ok,
      'trackAdmission2Ok': trackAdmission2Ok,
      'trackAdmission8Ok': trackAdmission8Ok,
      'trackAdmission9RejectedOk': trackAdmission9RejectedOk,
      'partialEosTailRenderedFrames': partialEosTailRenderedFrames,
      'partialEosTailPushedFrames': partialEosTailPushedFrames,
      'partialEosTailDrainedFrames': partialEosTailDrainedFrames,
      'partialEosTailPushedChecksumHex': partialEosTailPushedChecksumHex,
      'partialEosTailDrainedChecksumHex': partialEosTailDrainedChecksumHex,
      'reentrantHoldDispatchUnchangedOk': reentrantHoldDispatchUnchangedOk,
      'reentrantHoldPushedUnchangedOk': reentrantHoldPushedUnchangedOk,
      'reentrantForwardSeekNonQuiescentOk': reentrantForwardSeekNonQuiescentOk,
      'reentrantSeekForwardOk': reentrantSeekForwardOk,
      'reentrantSeekBackwardOk': reentrantSeekBackwardOk,
      'reentrantRestartAndEosOk': reentrantRestartAndEosOk,
      'pausedSeekStayedPaused': pausedSeekStayedPaused,
      'wrongOwnerStatus': wrongOwnerStatus,
      'wrongOwnerFlag': wrongOwnerFlag,
      'registryCapacityCount': registryCapacityCount,
      'registryFifthFailedOk': registryFifthFailedOk,
      'firstDestroyStatus': firstDestroyStatus,
      'firstDestroyWorkerJoined': firstDestroyWorkerJoined,
      'firstDestroyWorkerExited': firstDestroyWorkerExited,
      'nativeSecondDestroyStatus': nativeSecondDestroyStatus,
      'wrapperSecondDestroyStatus': wrapperSecondDestroyStatus,
      ...parsedMetrics,
    };

    return VGRealtimePlaybackTransportCoreSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: failureReason,
      details: details,
      trackAdmissionOk: trackAdmissionOk,
      partialEosTailOk: partialEosTailOk,
      reentrantSequenceOk: reentrantSequenceOk,
      pausedSeekStaysPausedOk: pausedSeekStaysPausedOk,
      wrongOwnerDirectProbeOk: wrongOwnerDirectProbeOk,
      registryCapacityOk: registryCapacityOk,
      destroyIdempotenceOk: destroyIdempotenceOk,
      proofBoundaryOk: proofBoundaryOk,
      canonical: canonical,
      trackAdmission1Ok: trackAdmission1Ok,
      trackAdmission2Ok: trackAdmission2Ok,
      trackAdmission8Ok: trackAdmission8Ok,
      trackAdmission9RejectedOk: trackAdmission9RejectedOk,
      partialEosTailRenderedFrames: partialEosTailRenderedFrames,
      partialEosTailPushedFrames: partialEosTailPushedFrames,
      partialEosTailDrainedFrames: partialEosTailDrainedFrames,
      partialEosTailPushedChecksumHex: partialEosTailPushedChecksumHex,
      partialEosTailDrainedChecksumHex: partialEosTailDrainedChecksumHex,
      reentrantHoldDispatchUnchangedOk: reentrantHoldDispatchUnchangedOk,
      reentrantHoldPushedUnchangedOk: reentrantHoldPushedUnchangedOk,
      reentrantForwardSeekNonQuiescentOk: reentrantForwardSeekNonQuiescentOk,
      reentrantSeekForwardOk: reentrantSeekForwardOk,
      reentrantSeekBackwardOk: reentrantSeekBackwardOk,
      reentrantRestartAndEosOk: reentrantRestartAndEosOk,
      pausedSeekStayedPaused: pausedSeekStayedPaused,
      wrongOwnerStatus: wrongOwnerStatus,
      wrongOwnerFlag: wrongOwnerFlag,
      registryCapacityCount: registryCapacityCount,
      registryFifthFailedOk: registryFifthFailedOk,
      firstDestroyStatus: firstDestroyStatus,
      firstDestroyWorkerJoined: firstDestroyWorkerJoined,
      firstDestroyWorkerExited: firstDestroyWorkerExited,
      nativeSecondDestroyStatus: nativeSecondDestroyStatus,
      wrapperSecondDestroyStatus: wrapperSecondDestroyStatus,
      lanes: Map<String, Object?>.unmodifiable(finalLanes),
      metrics: Map<String, Object?>.unmodifiable(finalMetrics),
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
      'nativeProofBoundary': nativeProofBoundary,
      'failureReason': failureReason,
      'details': details,
      'lanes': Map<String, Object?>.from(lanes),
      'metrics': Map<String, Object?>.from(metrics),
      'lastError': lastError,
    };
  }

  Map<String, Object?> toJson() => toMap();

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static VGRealtimePlaybackTransportCoreSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      'trackAdmissionOk': false,
      'partialEosTailOk': false,
      'reentrantSequenceOk': false,
      'pausedSeekStaysPausedOk': false,
      'wrongOwnerDirectProbeOk': false,
      'registryCapacityOk': false,
      'destroyIdempotenceOk': false,
      'proofBoundaryOk': false,
      'reentrantForwardSeekNonQuiescentOk': false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'trackAdmission1Ok': false,
      'trackAdmission2Ok': false,
      'trackAdmission8Ok': false,
      'trackAdmission9RejectedOk': false,
      'partialEosTailRenderedFrames': 0,
      'partialEosTailPushedFrames': 0,
      'partialEosTailDrainedFrames': 0,
      'partialEosTailPushedChecksumHex': '',
      'partialEosTailDrainedChecksumHex': '',
      'reentrantHoldDispatchUnchangedOk': false,
      'reentrantHoldPushedUnchangedOk': false,
      'reentrantForwardSeekNonQuiescentOk': false,
      'reentrantSeekForwardOk': false,
      'reentrantSeekBackwardOk': false,
      'reentrantRestartAndEosOk': false,
      'pausedSeekStayedPaused': false,
      'wrongOwnerStatus': '',
      'wrongOwnerFlag': false,
      'registryCapacityCount': 0,
      'registryFifthFailedOk': false,
      'firstDestroyStatus': '',
      'firstDestroyWorkerJoined': false,
      'firstDestroyWorkerExited': false,
      'nativeSecondDestroyStatus': '',
      'wrapperSecondDestroyStatus': '',
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGRealtimePlaybackTransportCoreSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      nativeProofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      trackAdmissionOk: false,
      partialEosTailOk: false,
      reentrantSequenceOk: false,
      pausedSeekStaysPausedOk: false,
      wrongOwnerDirectProbeOk: false,
      registryCapacityOk: false,
      destroyIdempotenceOk: false,
      proofBoundaryOk: false,
      canonical: false,
      trackAdmission1Ok: false,
      trackAdmission2Ok: false,
      trackAdmission8Ok: false,
      trackAdmission9RejectedOk: false,
      partialEosTailRenderedFrames: 0,
      partialEosTailPushedFrames: 0,
      partialEosTailDrainedFrames: 0,
      partialEosTailPushedChecksumHex: '',
      partialEosTailDrainedChecksumHex: '',
      reentrantHoldDispatchUnchangedOk: false,
      reentrantHoldPushedUnchangedOk: false,
      reentrantForwardSeekNonQuiescentOk: false,
      reentrantSeekForwardOk: false,
      reentrantSeekBackwardOk: false,
      reentrantRestartAndEosOk: false,
      pausedSeekStayedPaused: false,
      wrongOwnerStatus: '',
      wrongOwnerFlag: false,
      registryCapacityCount: 0,
      registryFifthFailedOk: false,
      firstDestroyStatus: '',
      firstDestroyWorkerJoined: false,
      firstDestroyWorkerExited: false,
      nativeSecondDestroyStatus: '',
      wrapperSecondDestroyStatus: '',
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
    );
  }

  /// Invokes the Android True-DAG Phase 4 Realtime Playback Transport Core
  /// diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation (defaults to 20 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGRealtimePlaybackTransportCoreSmokeReport>
  runRealtimePlaybackTransportCoreSmoke({
    Duration timeout = const Duration(seconds: 20),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = await future.timeout(timeout);
      return VGRealtimePlaybackTransportCoreSmokeReport.fromMap(raw);
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
    return other is VGRealtimePlaybackTransportCoreSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.nativeProofBoundary == nativeProofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.trackAdmissionOk == trackAdmissionOk &&
        other.partialEosTailOk == partialEosTailOk &&
        other.reentrantSequenceOk == reentrantSequenceOk &&
        other.pausedSeekStaysPausedOk == pausedSeekStaysPausedOk &&
        other.wrongOwnerDirectProbeOk == wrongOwnerDirectProbeOk &&
        other.registryCapacityOk == registryCapacityOk &&
        other.destroyIdempotenceOk == destroyIdempotenceOk &&
        other.proofBoundaryOk == proofBoundaryOk &&
        other.canonical == canonical &&
        other.trackAdmission1Ok == trackAdmission1Ok &&
        other.trackAdmission2Ok == trackAdmission2Ok &&
        other.trackAdmission8Ok == trackAdmission8Ok &&
        other.trackAdmission9RejectedOk == trackAdmission9RejectedOk &&
        other.partialEosTailRenderedFrames == partialEosTailRenderedFrames &&
        other.partialEosTailPushedFrames == partialEosTailPushedFrames &&
        other.partialEosTailDrainedFrames == partialEosTailDrainedFrames &&
        other.partialEosTailPushedChecksumHex ==
            partialEosTailPushedChecksumHex &&
        other.partialEosTailDrainedChecksumHex ==
            partialEosTailDrainedChecksumHex &&
        other.reentrantHoldDispatchUnchangedOk ==
            reentrantHoldDispatchUnchangedOk &&
        other.reentrantHoldPushedUnchangedOk ==
            reentrantHoldPushedUnchangedOk &&
        other.reentrantForwardSeekNonQuiescentOk ==
            reentrantForwardSeekNonQuiescentOk &&
        other.reentrantSeekForwardOk == reentrantSeekForwardOk &&
        other.reentrantSeekBackwardOk == reentrantSeekBackwardOk &&
        other.reentrantRestartAndEosOk == reentrantRestartAndEosOk &&
        other.pausedSeekStayedPaused == pausedSeekStayedPaused &&
        other.wrongOwnerStatus == wrongOwnerStatus &&
        other.wrongOwnerFlag == wrongOwnerFlag &&
        other.registryCapacityCount == registryCapacityCount &&
        other.registryFifthFailedOk == registryFifthFailedOk &&
        other.firstDestroyStatus == firstDestroyStatus &&
        other.firstDestroyWorkerJoined == firstDestroyWorkerJoined &&
        other.firstDestroyWorkerExited == firstDestroyWorkerExited &&
        other.nativeSecondDestroyStatus == nativeSecondDestroyStatus &&
        other.wrapperSecondDestroyStatus == wrapperSecondDestroyStatus &&
        mapEquals(other.lanes, lanes) &&
        mapEquals(other.metrics, metrics) &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hashAll([
    pass,
    status,
    marker,
    proofBoundary,
    nativeProofBoundary,
    failureReason,
    details,
    trackAdmissionOk,
    partialEosTailOk,
    reentrantSequenceOk,
    pausedSeekStaysPausedOk,
    wrongOwnerDirectProbeOk,
    registryCapacityOk,
    destroyIdempotenceOk,
    proofBoundaryOk,
    canonical,
    trackAdmission1Ok,
    trackAdmission2Ok,
    trackAdmission8Ok,
    trackAdmission9RejectedOk,
    partialEosTailRenderedFrames,
    partialEosTailPushedFrames,
    partialEosTailDrainedFrames,
    partialEosTailPushedChecksumHex,
    partialEosTailDrainedChecksumHex,
    reentrantHoldDispatchUnchangedOk,
    reentrantHoldPushedUnchangedOk,
    reentrantForwardSeekNonQuiescentOk,
    reentrantSeekForwardOk,
    reentrantSeekBackwardOk,
    reentrantRestartAndEosOk,
    pausedSeekStayedPaused,
    wrongOwnerStatus,
    wrongOwnerFlag,
    registryCapacityCount,
    registryFifthFailedOk,
    firstDestroyStatus,
    firstDestroyWorkerJoined,
    firstDestroyWorkerExited,
    nativeSecondDestroyStatus,
    wrapperSecondDestroyStatus,
    _stableMapHash(lanes),
    _stableMapHash(metrics),
    lastError,
  ]);

  static int _stableMapHash(Map<dynamic, dynamic> map) {
    final sortedKeys = map.keys.map((k) => k.toString()).toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGRealtimePlaybackTransportCoreSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'failureReason: $failureReason, '
      'trackAdmissionOk: $trackAdmissionOk, '
      'partialEosTailOk: $partialEosTailOk, '
      'reentrantSequenceOk: $reentrantSequenceOk, '
      'pausedSeekStaysPausedOk: $pausedSeekStaysPausedOk, '
      'wrongOwnerDirectProbeOk: $wrongOwnerDirectProbeOk, '
      'registryCapacityOk: $registryCapacityOk, '
      'destroyIdempotenceOk: $destroyIdempotenceOk, '
      'proofBoundaryOk: $proofBoundaryOk, '
      'reentrantForwardSeekNonQuiescentOk: $reentrantForwardSeekNonQuiescentOk, '
      'canonical: $canonical, '
      'lastError: $lastError)';
}
