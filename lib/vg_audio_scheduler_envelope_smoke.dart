// vg_audio_scheduler_envelope_smoke.dart
// vanguard_media_engine - P4-AUDIO-SCHEDULER-ENVELOPE-WIRING: Android True-DAG Phase 4
// GraphAudioScheduler per-source static-gain/envelope wiring diagnostic smoke foundation
// (sub-slice S under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AudioSchedulerEnvelopeSmoke` MethodChannel route.
// Diagnostic-only - validates GraphAudioScheduler per-source static gain and
// envelope params wiring, window PTS origin stamping across consecutive windows,
// multi-source parameter composition, null-envelope backward compatibility,
// mix-output envelope metric propagation, reject lanes (invalid gain, overflow,
// stale generation), and structural allocation/lifecycle guarantees.
//
// Honest non-claims (Proof Boundary):
// native_graph_audio_scheduler_envelope_wiring_diagnostic_only_scheduler_stamps_window_pts_origin_non_owning_per_source_static_gain_and_envelope_params_no_production_mixdown_change_no_export_reroute_no_pass2_reroute_no_runtime_queue_no_backpressure_no_realtime_sink_no_audio_track_no_aaudio_no_opensl_no_oboe_no_media_codec_no_media_extractor_no_file_io_no_native_worker_threads_no_app_no_editor_no_product_no_streaming_no_cache_no_ios

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAudioSchedulerEnvelopeSmokeReport.runAndroidDagPhase4AudioSchedulerEnvelopeSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAudioSchedulerEnvelopeSmokeReport {
  const VGAudioSchedulerEnvelopeSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.schedulerEnvelopeAppliedOk,
    required this.windowPtsOriginOk,
    required this.multiSourceParamsOk,
    required this.nullEnvelopeBackCompatOk,
    required this.mixOutputEnvelopeMetricsPropagatedOk,
    required this.invalidSourceGainFailClosedOk,
    required this.invalidEnvelopeGainFailClosedOk,
    required this.windowPtsOverflowRejectOk,
    required this.staleGenerationFailClosedOk,
    required this.noPerWindowAllocationOk,
    required this.lifecycleOk,
    required this.stackScoped,
    required this.canonical,
    required this.nativeStatus,
    required this.routedSourceCount,
    required this.windowFrames,
    required this.windowPtsUs0,
    required this.windowPtsUs1,
    required this.framesRenderedWindow0,
    required this.framesRenderedWindow1,
    required this.envelopeEvaluationsWindow0,
    required this.envelopeEvaluationsWindow1,
    required this.sampleRate,
    required this.channelCount,
    required this.maxFramesPerMix,
    required this.minEffectiveGainWindow0,
    required this.maxEffectiveGainWindow0,
    required this.schedulerChecksumWindow0Hex,
    required this.schedulerChecksumWindow1Hex,
    required this.referenceChecksumWindow0Hex,
    required this.referenceChecksumWindow1Hex,
    required this.unitGainChecksumWindow0Hex,
    required this.wrongOriginChecksumWindow1Hex,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidDagPhase4AudioSchedulerEnvelopeSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_AUDIO_SCHEDULER_ENVELOPE_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_AUDIO_SCHEDULER_ENVELOPE_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_graph_audio_scheduler_envelope_wiring_diagnostic_only_scheduler_stamps_window_pts_origin_non_owning_per_source_static_gain_and_envelope_params_no_production_mixdown_change_no_export_reroute_no_pass2_reroute_no_runtime_queue_no_backpressure_no_realtime_sink_no_audio_track_no_aaudio_no_opensl_no_oboe_no_media_codec_no_media_extractor_no_file_io_no_native_worker_threads_no_app_no_editor_no_product_no_streaming_no_cache_no_ios';

  /// All required native lane keys that must be present and reported.
  static const List<String> requiredNativeLaneKeys = <String>[
    'schedulerEnvelopeAppliedOk',
    'windowPtsOriginOk',
    'multiSourceParamsOk',
    'nullEnvelopeBackCompatOk',
    'mixOutputEnvelopeMetricsPropagatedOk',
    'invalidSourceGainFailClosedOk',
    'invalidEnvelopeGainFailClosedOk',
    'windowPtsOverflowRejectOk',
    'staleGenerationFailClosedOk',
    'noPerWindowAllocationOk',
    'lifecycleOk',
    'stackScoped',
  ];

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

  // ---- Lanes (13 lanes: 12 native + 1 canonical) --------------------------

  /// Whether scheduler-applied envelope output matches direct AudioMixBusNode reference mix.
  final bool schedulerEnvelopeAppliedOk;

  /// Whether scheduler stamps window PTS origin correctly across consecutive windows.
  final bool windowPtsOriginOk;

  /// Whether three-source params composition (envelope, static-gain, unit-null) matches reference.
  final bool multiSourceParamsOk;

  /// Whether missing/empty params map is bit-identical to baseline unit-gain/null-envelope output.
  final bool nullEnvelopeBackCompatOk;

  /// Whether envelope evaluations and effective min/max gain propagate to SchedulerOutput.
  final bool mixOutputEnvelopeMetricsPropagatedOk;

  /// Whether out-of-range static source gain is rejected without output mutation.
  final bool invalidSourceGainFailClosedOk;

  /// Whether out-of-range envelope gain is rejected without output mutation.
  final bool invalidEnvelopeGainFailClosedOk;

  /// Whether window PTS microsecond overflow is rejected before render.
  final bool windowPtsOverflowRejectOk;

  /// Whether stale generation is rejected without output mutation.
  final bool staleGenerationFailClosedOk;

  /// Whether no heap allocations occur during steady-state per-window render.
  final bool noPerWindowAllocationOk;

  /// Whether session lifecycle creation and cleanup are robust.
  final bool lifecycleOk;

  /// Whether JNI session and C++ node instances are strictly stack-scoped.
  final bool stackScoped;

  /// Canonical pass indicator.
  final bool canonical;

  // ---- Metrics (20 metrics) -----------------------------------------------

  /// Status string reported by the native layer ('PASS' / 'FAIL').
  final String nativeStatus;

  /// Number of active routed sources in the test graph (3).
  final int routedSourceCount;

  /// Number of frames per render window (typically 256).
  final int windowFrames;

  /// Starting PTS in microseconds for window 0.
  final int windowPtsUs0;

  /// Starting PTS in microseconds for window 1.
  final int windowPtsUs1;

  /// Frames rendered in window 0.
  final int framesRenderedWindow0;

  /// Frames rendered in window 1.
  final int framesRenderedWindow1;

  /// Number of envelope evaluations performed in window 0.
  final int envelopeEvaluationsWindow0;

  /// Number of envelope evaluations performed in window 1.
  final int envelopeEvaluationsWindow1;

  /// Audio sample rate in Hz (48000).
  final int sampleRate;

  /// Audio channel count (2).
  final int channelCount;

  /// Maximum frames per mix buffer capacity.
  final int maxFramesPerMix;

  /// Minimum effective gain observed during window 0.
  final double minEffectiveGainWindow0;

  /// Maximum effective gain observed during window 0.
  final double maxEffectiveGainWindow0;

  /// Checksum hex for scheduler render output of window 0.
  final String schedulerChecksumWindow0Hex;

  /// Checksum hex for scheduler render output of window 1.
  final String schedulerChecksumWindow1Hex;

  /// Checksum hex for reference AudioMixBusNode mix of window 0.
  final String referenceChecksumWindow0Hex;

  /// Checksum hex for reference AudioMixBusNode mix of window 1.
  final String referenceChecksumWindow1Hex;

  /// Checksum hex for unit-gain backward compatibility baseline window 0.
  final String unitGainChecksumWindow0Hex;

  /// Checksum hex produced when incorrect origin is supplied for window 1.
  final String wrongOriginChecksumWindow1Hex;

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

  // ---- Getters ------------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether [marker] matches the canonical pass marker constant.
  bool get hasPassMarker => marker == passMarkerConstant;

  /// Whether [marker] matches the canonical fail marker constant.
  bool get hasFailMarker => marker == failMarkerConstant;

  /// Whether window 0 scheduler output matches direct reference mix.
  bool get window0MatchesReference =>
      schedulerChecksumWindow0Hex.isNotEmpty &&
      referenceChecksumWindow0Hex.isNotEmpty &&
      schedulerChecksumWindow0Hex == referenceChecksumWindow0Hex;

  /// Whether window 1 scheduler output matches direct reference mix.
  bool get window1MatchesReference =>
      schedulerChecksumWindow1Hex.isNotEmpty &&
      referenceChecksumWindow1Hex.isNotEmpty &&
      schedulerChecksumWindow1Hex == referenceChecksumWindow1Hex;

  /// Whether all native diagnostic lanes passed according to the contract.
  bool get allNativeLanesPass {
    if (!pass) return false;
    if (status.toLowerCase() != 'pass') return false;
    if (!hasCanonicalProofBoundary) return false;
    if (!hasPassMarker) return false;
    if (!schedulerEnvelopeAppliedOk) return false;
    if (!windowPtsOriginOk) return false;
    if (!multiSourceParamsOk) return false;
    if (!nullEnvelopeBackCompatOk) return false;
    if (!mixOutputEnvelopeMetricsPropagatedOk) return false;
    if (!invalidSourceGainFailClosedOk) return false;
    if (!invalidEnvelopeGainFailClosedOk) return false;
    if (!windowPtsOverflowRejectOk) return false;
    if (!staleGenerationFailClosedOk) return false;
    if (!noPerWindowAllocationOk) return false;
    if (!lifecycleOk) return false;
    if (!stackScoped) return false;
    if (!canonical) return false;
    if (lastError.isNotEmpty && lastError != 'none' && lastError != 'null') {
      return false;
    }
    return true;
  }

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAudioSchedulerEnvelopeSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAudioSchedulerEnvelopeSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        schedulerEnvelopeAppliedOk: false,
        windowPtsOriginOk: false,
        multiSourceParamsOk: false,
        nullEnvelopeBackCompatOk: false,
        mixOutputEnvelopeMetricsPropagatedOk: false,
        invalidSourceGainFailClosedOk: false,
        invalidEnvelopeGainFailClosedOk: false,
        windowPtsOverflowRejectOk: false,
        staleGenerationFailClosedOk: false,
        noPerWindowAllocationOk: false,
        lifecycleOk: false,
        stackScoped: false,
        canonical: false,
        nativeStatus: 'FAIL',
        routedSourceCount: 0,
        windowFrames: 0,
        windowPtsUs0: 0,
        windowPtsUs1: 0,
        framesRenderedWindow0: 0,
        framesRenderedWindow1: 0,
        envelopeEvaluationsWindow0: 0,
        envelopeEvaluationsWindow1: 0,
        sampleRate: 0,
        channelCount: 0,
        maxFramesPerMix: 0,
        minEffectiveGainWindow0: 0.0,
        maxEffectiveGainWindow0: 0.0,
        schedulerChecksumWindow0Hex: '',
        schedulerChecksumWindow1Hex: '',
        referenceChecksumWindow0Hex: '',
        referenceChecksumWindow1Hex: '',
        unitGainChecksumWindow0Hex: '',
        wrongOriginChecksumWindow1Hex: '',
        lanes: <String, Object?>{
          'schedulerEnvelopeAppliedOk': false,
          'windowPtsOriginOk': false,
          'multiSourceParamsOk': false,
          'nullEnvelopeBackCompatOk': false,
          'mixOutputEnvelopeMetricsPropagatedOk': false,
          'invalidSourceGainFailClosedOk': false,
          'invalidEnvelopeGainFailClosedOk': false,
          'windowPtsOverflowRejectOk': false,
          'staleGenerationFailClosedOk': false,
          'noPerWindowAllocationOk': false,
          'lifecycleOk': false,
          'stackScoped': false,
          'canonical': false,
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

    double? parseDoubleStrict(String key) {
      final v = parsedMetrics[key] ?? raw[key] ?? parsedLanes[key];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v.trim());
      return null;
    }

    double parseDouble(String key, [double defaultValue = 0.0]) {
      return parseDoubleStrict(key) ?? defaultValue;
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
    final failureReason = parseString('failureReason');
    final details = parseString('details');

    final missingLanes = <String>[];
    for (final laneKey in requiredNativeLaneKeys) {
      if (parseBoolStrict(laneKey) == null) {
        missingLanes.add(laneKey);
      }
    }

    final schedulerEnvelopeAppliedOk = parseBool('schedulerEnvelopeAppliedOk');
    final windowPtsOriginOk = parseBool('windowPtsOriginOk');
    final multiSourceParamsOk = parseBool('multiSourceParamsOk');
    final nullEnvelopeBackCompatOk = parseBool('nullEnvelopeBackCompatOk');
    final mixOutputEnvelopeMetricsPropagatedOk = parseBool(
      'mixOutputEnvelopeMetricsPropagatedOk',
    );
    final invalidSourceGainFailClosedOk = parseBool(
      'invalidSourceGainFailClosedOk',
    );
    final invalidEnvelopeGainFailClosedOk = parseBool(
      'invalidEnvelopeGainFailClosedOk',
    );
    final windowPtsOverflowRejectOk = parseBool('windowPtsOverflowRejectOk');
    final staleGenerationFailClosedOk = parseBool(
      'staleGenerationFailClosedOk',
    );
    final noPerWindowAllocationOk = parseBool('noPerWindowAllocationOk');
    final lifecycleOk = parseBool('lifecycleOk');
    final stackScoped = parseBool('stackScoped');
    final canonical = parseBool('canonical', rawPass && missingLanes.isEmpty);

    final nativeStatus = parseString('nativeStatus');
    final routedSourceCount = parseInt('routedSourceCount');
    final windowFrames = parseInt('windowFrames');
    final windowPtsUs0 = parseInt('windowPtsUs0');
    final windowPtsUs1 = parseInt('windowPtsUs1');
    final framesRenderedWindow0 = parseInt('framesRenderedWindow0');
    final framesRenderedWindow1 = parseInt('framesRenderedWindow1');
    final envelopeEvaluationsWindow0 = parseInt('envelopeEvaluationsWindow0');
    final envelopeEvaluationsWindow1 = parseInt('envelopeEvaluationsWindow1');
    final sampleRate = parseInt('sampleRate');
    final channelCount = parseInt('channelCount');
    final maxFramesPerMix = parseInt('maxFramesPerMix');
    final minEffectiveGainWindow0 = parseDouble('minEffectiveGainWindow0');
    final maxEffectiveGainWindow0 = parseDouble('maxEffectiveGainWindow0');
    final schedulerChecksumWindow0Hex = parseString(
      'schedulerChecksumWindow0Hex',
    );
    final schedulerChecksumWindow1Hex = parseString(
      'schedulerChecksumWindow1Hex',
    );
    final referenceChecksumWindow0Hex = parseString(
      'referenceChecksumWindow0Hex',
    );
    final referenceChecksumWindow1Hex = parseString(
      'referenceChecksumWindow1Hex',
    );
    final unitGainChecksumWindow0Hex = parseString(
      'unitGainChecksumWindow0Hex',
    );
    final wrongOriginChecksumWindow1Hex = parseString(
      'wrongOriginChecksumWindow1Hex',
    );

    final hasValidProofBoundary = proofBoundary == proofBoundaryConstant;
    final hasValidPassMarker = rawMarker == passMarkerConstant;

    final allRequiredLanesTrue =
        schedulerEnvelopeAppliedOk &&
        windowPtsOriginOk &&
        multiSourceParamsOk &&
        nullEnvelopeBackCompatOk &&
        mixOutputEnvelopeMetricsPropagatedOk &&
        invalidSourceGainFailClosedOk &&
        invalidEnvelopeGainFailClosedOk &&
        windowPtsOverflowRejectOk &&
        staleGenerationFailClosedOk &&
        noPerWindowAllocationOk &&
        lifecycleOk &&
        stackScoped &&
        canonical;

    final allRequiredLanesPresent = missingLanes.isEmpty;

    final pass =
        rawPass &&
        rawStatus.toLowerCase() == 'pass' &&
        hasValidPassMarker &&
        hasValidProofBoundary &&
        allRequiredLanesPresent &&
        allRequiredLanesTrue;

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
      final explicitError = parseString('lastError');
      if (failureReason.isNotEmpty) {
        lastError = failureReason;
        status = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      } else if (explicitError.isNotEmpty) {
        lastError = explicitError;
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
      'schedulerEnvelopeAppliedOk': schedulerEnvelopeAppliedOk,
      'windowPtsOriginOk': windowPtsOriginOk,
      'multiSourceParamsOk': multiSourceParamsOk,
      'nullEnvelopeBackCompatOk': nullEnvelopeBackCompatOk,
      'mixOutputEnvelopeMetricsPropagatedOk':
          mixOutputEnvelopeMetricsPropagatedOk,
      'invalidSourceGainFailClosedOk': invalidSourceGainFailClosedOk,
      'invalidEnvelopeGainFailClosedOk': invalidEnvelopeGainFailClosedOk,
      'windowPtsOverflowRejectOk': windowPtsOverflowRejectOk,
      'staleGenerationFailClosedOk': staleGenerationFailClosedOk,
      'noPerWindowAllocationOk': noPerWindowAllocationOk,
      'lifecycleOk': lifecycleOk,
      'stackScoped': stackScoped,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{
      'nativeStatus': nativeStatus,
      'routedSourceCount': routedSourceCount,
      'windowFrames': windowFrames,
      'windowPtsUs0': windowPtsUs0,
      'windowPtsUs1': windowPtsUs1,
      'framesRenderedWindow0': framesRenderedWindow0,
      'framesRenderedWindow1': framesRenderedWindow1,
      'envelopeEvaluationsWindow0': envelopeEvaluationsWindow0,
      'envelopeEvaluationsWindow1': envelopeEvaluationsWindow1,
      'sampleRate': sampleRate,
      'channelCount': channelCount,
      'maxFramesPerMix': maxFramesPerMix,
      'minEffectiveGainWindow0': minEffectiveGainWindow0,
      'maxEffectiveGainWindow0': maxEffectiveGainWindow0,
      'schedulerChecksumWindow0Hex': schedulerChecksumWindow0Hex,
      'schedulerChecksumWindow1Hex': schedulerChecksumWindow1Hex,
      'referenceChecksumWindow0Hex': referenceChecksumWindow0Hex,
      'referenceChecksumWindow1Hex': referenceChecksumWindow1Hex,
      'unitGainChecksumWindow0Hex': unitGainChecksumWindow0Hex,
      'wrongOriginChecksumWindow1Hex': wrongOriginChecksumWindow1Hex,
      ...parsedMetrics,
    };

    return VGAudioSchedulerEnvelopeSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      details: details,
      schedulerEnvelopeAppliedOk: schedulerEnvelopeAppliedOk,
      windowPtsOriginOk: windowPtsOriginOk,
      multiSourceParamsOk: multiSourceParamsOk,
      nullEnvelopeBackCompatOk: nullEnvelopeBackCompatOk,
      mixOutputEnvelopeMetricsPropagatedOk:
          mixOutputEnvelopeMetricsPropagatedOk,
      invalidSourceGainFailClosedOk: invalidSourceGainFailClosedOk,
      invalidEnvelopeGainFailClosedOk: invalidEnvelopeGainFailClosedOk,
      windowPtsOverflowRejectOk: windowPtsOverflowRejectOk,
      staleGenerationFailClosedOk: staleGenerationFailClosedOk,
      noPerWindowAllocationOk: noPerWindowAllocationOk,
      lifecycleOk: lifecycleOk,
      stackScoped: stackScoped,
      canonical: canonical,
      nativeStatus: nativeStatus,
      routedSourceCount: routedSourceCount,
      windowFrames: windowFrames,
      windowPtsUs0: windowPtsUs0,
      windowPtsUs1: windowPtsUs1,
      framesRenderedWindow0: framesRenderedWindow0,
      framesRenderedWindow1: framesRenderedWindow1,
      envelopeEvaluationsWindow0: envelopeEvaluationsWindow0,
      envelopeEvaluationsWindow1: envelopeEvaluationsWindow1,
      sampleRate: sampleRate,
      channelCount: channelCount,
      maxFramesPerMix: maxFramesPerMix,
      minEffectiveGainWindow0: minEffectiveGainWindow0,
      maxEffectiveGainWindow0: maxEffectiveGainWindow0,
      schedulerChecksumWindow0Hex: schedulerChecksumWindow0Hex,
      schedulerChecksumWindow1Hex: schedulerChecksumWindow1Hex,
      referenceChecksumWindow0Hex: referenceChecksumWindow0Hex,
      referenceChecksumWindow1Hex: referenceChecksumWindow1Hex,
      unitGainChecksumWindow0Hex: unitGainChecksumWindow0Hex,
      wrongOriginChecksumWindow1Hex: wrongOriginChecksumWindow1Hex,
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
      'failureReason': failureReason,
      'details': details,
      'lanes': Map<String, Object?>.from(lanes),
      'metrics': Map<String, Object?>.from(metrics),
      'lastError': lastError,
    };
  }

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static VGAudioSchedulerEnvelopeSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      'schedulerEnvelopeAppliedOk': false,
      'windowPtsOriginOk': false,
      'multiSourceParamsOk': false,
      'nullEnvelopeBackCompatOk': false,
      'mixOutputEnvelopeMetricsPropagatedOk': false,
      'invalidSourceGainFailClosedOk': false,
      'invalidEnvelopeGainFailClosedOk': false,
      'windowPtsOverflowRejectOk': false,
      'staleGenerationFailClosedOk': false,
      'noPerWindowAllocationOk': false,
      'lifecycleOk': false,
      'stackScoped': false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'nativeStatus': 'FAIL',
      'routedSourceCount': 0,
      'windowFrames': 0,
      'windowPtsUs0': 0,
      'windowPtsUs1': 0,
      'framesRenderedWindow0': 0,
      'framesRenderedWindow1': 0,
      'envelopeEvaluationsWindow0': 0,
      'envelopeEvaluationsWindow1': 0,
      'sampleRate': 0,
      'channelCount': 0,
      'maxFramesPerMix': 0,
      'minEffectiveGainWindow0': 0.0,
      'maxEffectiveGainWindow0': 0.0,
      'schedulerChecksumWindow0Hex': '',
      'schedulerChecksumWindow1Hex': '',
      'referenceChecksumWindow0Hex': '',
      'referenceChecksumWindow1Hex': '',
      'unitGainChecksumWindow0Hex': '',
      'wrongOriginChecksumWindow1Hex': '',
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGAudioSchedulerEnvelopeSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      schedulerEnvelopeAppliedOk: false,
      windowPtsOriginOk: false,
      multiSourceParamsOk: false,
      nullEnvelopeBackCompatOk: false,
      mixOutputEnvelopeMetricsPropagatedOk: false,
      invalidSourceGainFailClosedOk: false,
      invalidEnvelopeGainFailClosedOk: false,
      windowPtsOverflowRejectOk: false,
      staleGenerationFailClosedOk: false,
      noPerWindowAllocationOk: false,
      lifecycleOk: false,
      stackScoped: false,
      canonical: false,
      nativeStatus: 'FAIL',
      routedSourceCount: 0,
      windowFrames: 0,
      windowPtsUs0: 0,
      windowPtsUs1: 0,
      framesRenderedWindow0: 0,
      framesRenderedWindow1: 0,
      envelopeEvaluationsWindow0: 0,
      envelopeEvaluationsWindow1: 0,
      sampleRate: 0,
      channelCount: 0,
      maxFramesPerMix: 0,
      minEffectiveGainWindow0: 0.0,
      maxEffectiveGainWindow0: 0.0,
      schedulerChecksumWindow0Hex: '',
      schedulerChecksumWindow1Hex: '',
      referenceChecksumWindow0Hex: '',
      referenceChecksumWindow1Hex: '',
      unitGainChecksumWindow0Hex: '',
      wrongOriginChecksumWindow1Hex: '',
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
    );
  }

  /// Invokes the Android True-DAG Phase 4 GraphAudioScheduler per-source
  /// static-gain/envelope wiring diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation (defaults to 20 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAudioSchedulerEnvelopeSmokeReport>
  runAndroidDagPhase4AudioSchedulerEnvelopeSmoke({
    Duration timeout = const Duration(seconds: 20),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = await future.timeout(timeout);
      return VGAudioSchedulerEnvelopeSmokeReport.fromMap(raw);
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
    return other is VGAudioSchedulerEnvelopeSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.schedulerEnvelopeAppliedOk == schedulerEnvelopeAppliedOk &&
        other.windowPtsOriginOk == windowPtsOriginOk &&
        other.multiSourceParamsOk == multiSourceParamsOk &&
        other.nullEnvelopeBackCompatOk == nullEnvelopeBackCompatOk &&
        other.mixOutputEnvelopeMetricsPropagatedOk ==
            mixOutputEnvelopeMetricsPropagatedOk &&
        other.invalidSourceGainFailClosedOk == invalidSourceGainFailClosedOk &&
        other.invalidEnvelopeGainFailClosedOk ==
            invalidEnvelopeGainFailClosedOk &&
        other.windowPtsOverflowRejectOk == windowPtsOverflowRejectOk &&
        other.staleGenerationFailClosedOk == staleGenerationFailClosedOk &&
        other.noPerWindowAllocationOk == noPerWindowAllocationOk &&
        other.lifecycleOk == lifecycleOk &&
        other.stackScoped == stackScoped &&
        other.canonical == canonical &&
        other.nativeStatus == nativeStatus &&
        other.routedSourceCount == routedSourceCount &&
        other.windowFrames == windowFrames &&
        other.windowPtsUs0 == windowPtsUs0 &&
        other.windowPtsUs1 == windowPtsUs1 &&
        other.framesRenderedWindow0 == framesRenderedWindow0 &&
        other.framesRenderedWindow1 == framesRenderedWindow1 &&
        other.envelopeEvaluationsWindow0 == envelopeEvaluationsWindow0 &&
        other.envelopeEvaluationsWindow1 == envelopeEvaluationsWindow1 &&
        other.sampleRate == sampleRate &&
        other.channelCount == channelCount &&
        other.maxFramesPerMix == maxFramesPerMix &&
        other.minEffectiveGainWindow0 == minEffectiveGainWindow0 &&
        other.maxEffectiveGainWindow0 == maxEffectiveGainWindow0 &&
        other.schedulerChecksumWindow0Hex == schedulerChecksumWindow0Hex &&
        other.schedulerChecksumWindow1Hex == schedulerChecksumWindow1Hex &&
        other.referenceChecksumWindow0Hex == referenceChecksumWindow0Hex &&
        other.referenceChecksumWindow1Hex == referenceChecksumWindow1Hex &&
        other.unitGainChecksumWindow0Hex == unitGainChecksumWindow0Hex &&
        other.wrongOriginChecksumWindow1Hex == wrongOriginChecksumWindow1Hex &&
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
    failureReason,
    details,
    schedulerEnvelopeAppliedOk,
    windowPtsOriginOk,
    multiSourceParamsOk,
    nullEnvelopeBackCompatOk,
    mixOutputEnvelopeMetricsPropagatedOk,
    invalidSourceGainFailClosedOk,
    invalidEnvelopeGainFailClosedOk,
    windowPtsOverflowRejectOk,
    staleGenerationFailClosedOk,
    noPerWindowAllocationOk,
    lifecycleOk,
    stackScoped,
    canonical,
    nativeStatus,
    routedSourceCount,
    windowFrames,
    windowPtsUs0,
    windowPtsUs1,
    framesRenderedWindow0,
    framesRenderedWindow1,
    envelopeEvaluationsWindow0,
    envelopeEvaluationsWindow1,
    sampleRate,
    channelCount,
    maxFramesPerMix,
    minEffectiveGainWindow0,
    maxEffectiveGainWindow0,
    schedulerChecksumWindow0Hex,
    schedulerChecksumWindow1Hex,
    referenceChecksumWindow0Hex,
    referenceChecksumWindow1Hex,
    unitGainChecksumWindow0Hex,
    wrongOriginChecksumWindow1Hex,
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
      'VGAudioSchedulerEnvelopeSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'failureReason: $failureReason, '
      'schedulerEnvelopeAppliedOk: $schedulerEnvelopeAppliedOk, '
      'windowPtsOriginOk: $windowPtsOriginOk, '
      'multiSourceParamsOk: $multiSourceParamsOk, '
      'nullEnvelopeBackCompatOk: $nullEnvelopeBackCompatOk, '
      'mixOutputEnvelopeMetricsPropagatedOk: $mixOutputEnvelopeMetricsPropagatedOk, '
      'invalidSourceGainFailClosedOk: $invalidSourceGainFailClosedOk, '
      'invalidEnvelopeGainFailClosedOk: $invalidEnvelopeGainFailClosedOk, '
      'windowPtsOverflowRejectOk: $windowPtsOverflowRejectOk, '
      'staleGenerationFailClosedOk: $staleGenerationFailClosedOk, '
      'noPerWindowAllocationOk: $noPerWindowAllocationOk, '
      'lifecycleOk: $lifecycleOk, '
      'stackScoped: $stackScoped, '
      'canonical: $canonical, '
      'nativeStatus: $nativeStatus, '
      'routedSourceCount: $routedSourceCount, '
      'windowFrames: $windowFrames, '
      'windowPtsUs0: $windowPtsUs0, '
      'windowPtsUs1: $windowPtsUs1, '
      'framesRenderedWindow0: $framesRenderedWindow0, '
      'framesRenderedWindow1: $framesRenderedWindow1, '
      'envelopeEvaluationsWindow0: $envelopeEvaluationsWindow0, '
      'envelopeEvaluationsWindow1: $envelopeEvaluationsWindow1, '
      'sampleRate: $sampleRate, '
      'channelCount: $channelCount, '
      'maxFramesPerMix: $maxFramesPerMix, '
      'minEffectiveGainWindow0: $minEffectiveGainWindow0, '
      'maxEffectiveGainWindow0: $maxEffectiveGainWindow0, '
      'schedulerChecksumWindow0Hex: $schedulerChecksumWindow0Hex, '
      'schedulerChecksumWindow1Hex: $schedulerChecksumWindow1Hex, '
      'referenceChecksumWindow0Hex: $referenceChecksumWindow0Hex, '
      'referenceChecksumWindow1Hex: $referenceChecksumWindow1Hex, '
      'unitGainChecksumWindow0Hex: $unitGainChecksumWindow0Hex, '
      'wrongOriginChecksumWindow1Hex: $wrongOriginChecksumWindow1Hex, '
      'lastError: $lastError)';
}
