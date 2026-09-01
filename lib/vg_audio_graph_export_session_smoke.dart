// vg_audio_graph_export_session_smoke.dart
// vanguard_media_engine - P4-AUDIO-PASS2-GRAPH-NATIVE-SESSION: Android True-DAG Phase 4
// N-source node-owned ring audio graph export session diagnostic smoke foundation
// (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AudioGraphExportSessionSmoke` MethodChannel route.
// Diagnostic-only - validates parameterized N-source native True-DAG audio graph export session,
// multi-track admission, long timeline admission, track capacity limit rejection, prepare barrier,
// routed source discovery, lockstep full-window ingest, contiguous window render, deterministic
// checksum matching reference mix math, underrun fail-closed rejection, and idempotent lifecycle destroy.
//
// Honest non-claims (Proof Boundary):
// native_true_dag_pass2_graph_export_session_diagnostic_only_n_source_node_owned_ring_graph_scheduler_mixbus_unit_gain_no_production_route_swap_no_android_mixdown_engine_change_no_legacy_chunk_mixer_change_no_runtime_realtime_sink_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_mediacodec_no_mediaextractor_no_file_io_no_native_worker_threads_no_app_no_editor_no_product_no_streaming_no_cache_no_ios

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAudioGraphExportSessionSmokeReport.runAndroidDagPhase4AudioGraphExportSessionSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAudioGraphExportSessionSmokeReport {
  const VGAudioGraphExportSessionSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.sessionCreateOk,
    required this.longTimelineAdmissionOk,
    required this.addEightTracksOk,
    required this.totalTrackLimitRejectOk,
    required this.prepareBarrierOk,
    required this.routedSourceCountOk,
    required this.contiguousWindowOk,
    required this.renderTwoWindowsOk,
    required this.checksumNonZeroOk,
    required this.underrunFailClosedOk,
    required this.lifecycleDestroyIdempotentOk,
    required this.proofBoundaryOk,
    required this.noProductionRouteSwapOk,
    required this.canonical,
    required this.requestedTrackCount,
    required this.routedSourceCount,
    required this.windowCount,
    required this.silentWindowCount,
    required this.framesRendered,
    required this.longTimelineFrames,
    required this.totalTrackLimitReason,
    required this.nonContiguousReason,
    required this.underrunReason,
    required this.checksumWindow0Hex,
    required this.checksumWindow1Hex,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidDagPhase4AudioGraphExportSessionSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_AUDIO_GRAPH_EXPORT_SESSION_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_AUDIO_GRAPH_EXPORT_SESSION_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_true_dag_pass2_graph_export_session_diagnostic_only_n_source_node_owned_ring_graph_scheduler_mixbus_unit_gain_no_production_route_swap_no_android_mixdown_engine_change_no_legacy_chunk_mixer_change_no_runtime_realtime_sink_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_mediacodec_no_mediaextractor_no_file_io_no_native_worker_threads_no_app_no_editor_no_product_no_streaming_no_cache_no_ios';

  /// All required native lane keys that must be present and reported.
  static const List<String> requiredNativeLaneKeys = <String>[
    'sessionCreateOk',
    'longTimelineAdmissionOk',
    'addEightTracksOk',
    'totalTrackLimitRejectOk',
    'prepareBarrierOk',
    'routedSourceCountOk',
    'contiguousWindowOk',
    'renderTwoWindowsOk',
    'checksumNonZeroOk',
    'underrunFailClosedOk',
    'lifecycleDestroyIdempotentOk',
    'proofBoundaryOk',
    'noProductionRouteSwapOk',
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

  // ---- Lanes (14 lanes: 13 native + 1 canonical) --------------------------

  /// Whether export session creation succeeded with valid handle.
  final bool sessionCreateOk;

  /// Whether 600-second long timeline track admission succeeded.
  final bool longTimelineAdmissionOk;

  /// Whether adding 8 tracks to the session succeeded with sequential track indices.
  final bool addEightTracksOk;

  /// Whether adding a 9th track was rejected due to total track capacity limit.
  final bool totalTrackLimitRejectOk;

  /// Whether pre-prepare ingest/render and post-prepare addTrack fail closed.
  final bool prepareBarrierOk;

  /// Whether auto-discovery found and routed all requested tracks (8/8).
  final bool routedSourceCountOk;

  /// Whether non-contiguous window render attempts are rejected.
  final bool contiguousWindowOk;

  /// Whether two consecutive windows render correctly without underrun or silence.
  final bool renderTwoWindowsOk;

  /// Whether mixed output checksums are non-zero and bit-exactly match reference mix math.
  final bool checksumNonZeroOk;

  /// Whether rendering an unpopulated track fails closed with source_underrun.
  final bool underrunFailClosedOk;

  /// Whether session destroy is idempotent and repeatable.
  final bool lifecycleDestroyIdempotentOk;

  /// Whether proof boundary matches byte-identically.
  final bool proofBoundaryOk;

  /// Whether production routes (AndroidAudioMixdownEngine, legacy ChunkMixer) remain untouched.
  final bool noProductionRouteSwapOk;

  /// Canonical pass indicator.
  final bool canonical;

  // ---- Metrics ------------------------------------------------------------

  /// Total number of tracks requested in the session.
  final int requestedTrackCount;

  /// Number of tracks successfully routed in the audio graph.
  final int routedSourceCount;

  /// Total count of rendered windows.
  final int windowCount;

  /// Count of silent rendered windows (must be 0).
  final int silentWindowCount;

  /// Total PCM frames rendered across all windows.
  final int framesRendered;

  /// Long timeline admission frame count (e.g. 48000 * 600).
  final int longTimelineFrames;

  /// Total track limit rejection reason string when 9th track is added.
  final String totalTrackLimitReason;

  /// Non-contiguous window rejection reason string.
  final String nonContiguousReason;

  /// Underrun rejection reason string when unpopulated track is rendered.
  final String underrunReason;

  /// Checksum hex for mixed output of window 0.
  final String checksumWindow0Hex;

  /// Checksum hex for mixed output of window 1.
  final String checksumWindow1Hex;

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

  /// Whether all native diagnostic lanes passed according to the contract.
  bool get allNativeLanesPass {
    if (!pass) return false;
    if (status.toLowerCase() != 'pass') return false;
    if (!hasCanonicalProofBoundary) return false;
    if (!hasPassMarker) return false;
    if (!sessionCreateOk) return false;
    if (!longTimelineAdmissionOk) return false;
    if (!addEightTracksOk) return false;
    if (!totalTrackLimitRejectOk) return false;
    if (!prepareBarrierOk) return false;
    if (!routedSourceCountOk) return false;
    if (!contiguousWindowOk) return false;
    if (!renderTwoWindowsOk) return false;
    if (!checksumNonZeroOk) return false;
    if (!underrunFailClosedOk) return false;
    if (!lifecycleDestroyIdempotentOk) return false;
    if (!proofBoundaryOk) return false;
    if (!noProductionRouteSwapOk) return false;
    if (!canonical) return false;
    if (lastError.isNotEmpty && lastError != 'none' && lastError != 'null') {
      return false;
    }
    return true;
  }

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAudioGraphExportSessionSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAudioGraphExportSessionSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        sessionCreateOk: false,
        longTimelineAdmissionOk: false,
        addEightTracksOk: false,
        totalTrackLimitRejectOk: false,
        prepareBarrierOk: false,
        routedSourceCountOk: false,
        contiguousWindowOk: false,
        renderTwoWindowsOk: false,
        checksumNonZeroOk: false,
        underrunFailClosedOk: false,
        lifecycleDestroyIdempotentOk: false,
        proofBoundaryOk: false,
        noProductionRouteSwapOk: false,
        canonical: false,
        requestedTrackCount: 0,
        routedSourceCount: 0,
        windowCount: 0,
        silentWindowCount: 0,
        framesRendered: 0,
        longTimelineFrames: 0,
        totalTrackLimitReason: '',
        nonContiguousReason: '',
        underrunReason: '',
        checksumWindow0Hex: '',
        checksumWindow1Hex: '',
        lanes: <String, Object?>{
          'sessionCreateOk': false,
          'longTimelineAdmissionOk': false,
          'addEightTracksOk': false,
          'totalTrackLimitRejectOk': false,
          'prepareBarrierOk': false,
          'routedSourceCountOk': false,
          'contiguousWindowOk': false,
          'renderTwoWindowsOk': false,
          'checksumNonZeroOk': false,
          'underrunFailClosedOk': false,
          'lifecycleDestroyIdempotentOk': false,
          'proofBoundaryOk': false,
          'noProductionRouteSwapOk': false,
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

    final sessionCreateOk = parseBool('sessionCreateOk');
    final longTimelineAdmissionOk = parseBool('longTimelineAdmissionOk');
    final addEightTracksOk = parseBool('addEightTracksOk');
    final totalTrackLimitRejectOk = parseBool('totalTrackLimitRejectOk');
    final prepareBarrierOk = parseBool('prepareBarrierOk');
    final routedSourceCountOk = parseBool('routedSourceCountOk');
    final contiguousWindowOk = parseBool('contiguousWindowOk');
    final renderTwoWindowsOk = parseBool('renderTwoWindowsOk');
    final checksumNonZeroOk = parseBool('checksumNonZeroOk');
    final underrunFailClosedOk = parseBool('underrunFailClosedOk');
    final lifecycleDestroyIdempotentOk = parseBool(
      'lifecycleDestroyIdempotentOk',
    );
    final proofBoundaryOk = parseBool('proofBoundaryOk');
    final noProductionRouteSwapOk = parseBool('noProductionRouteSwapOk');
    final canonical = parseBool('canonical', rawPass && missingLanes.isEmpty);

    final requestedTrackCount = parseInt('requestedTrackCount');
    final routedSourceCount = parseInt('routedSourceCount');
    final windowCount = parseInt('windowCount');
    final silentWindowCount = parseInt('silentWindowCount');
    final framesRendered = parseInt('framesRendered');
    final longTimelineFrames = parseInt('longTimelineFrames');
    final totalTrackLimitReason = parseString('totalTrackLimitReason');
    final nonContiguousReason = parseString('nonContiguousReason');
    final underrunReason = parseString('underrunReason');
    final checksumWindow0Hex = parseString('checksumWindow0Hex');
    final checksumWindow1Hex = parseString('checksumWindow1Hex');

    final hasValidProofBoundary = proofBoundary == proofBoundaryConstant;
    final hasValidPassMarker = rawMarker == passMarkerConstant;

    final allRequiredLanesTrue =
        sessionCreateOk &&
        longTimelineAdmissionOk &&
        addEightTracksOk &&
        totalTrackLimitRejectOk &&
        prepareBarrierOk &&
        routedSourceCountOk &&
        contiguousWindowOk &&
        renderTwoWindowsOk &&
        checksumNonZeroOk &&
        underrunFailClosedOk &&
        lifecycleDestroyIdempotentOk &&
        proofBoundaryOk &&
        noProductionRouteSwapOk &&
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
      'sessionCreateOk': sessionCreateOk,
      'longTimelineAdmissionOk': longTimelineAdmissionOk,
      'addEightTracksOk': addEightTracksOk,
      'totalTrackLimitRejectOk': totalTrackLimitRejectOk,
      'prepareBarrierOk': prepareBarrierOk,
      'routedSourceCountOk': routedSourceCountOk,
      'contiguousWindowOk': contiguousWindowOk,
      'renderTwoWindowsOk': renderTwoWindowsOk,
      'checksumNonZeroOk': checksumNonZeroOk,
      'underrunFailClosedOk': underrunFailClosedOk,
      'lifecycleDestroyIdempotentOk': lifecycleDestroyIdempotentOk,
      'proofBoundaryOk': proofBoundaryOk,
      'noProductionRouteSwapOk': noProductionRouteSwapOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{
      'requestedTrackCount': requestedTrackCount,
      'routedSourceCount': routedSourceCount,
      'windowCount': windowCount,
      'silentWindowCount': silentWindowCount,
      'framesRendered': framesRendered,
      'longTimelineFrames': longTimelineFrames,
      'totalTrackLimitReason': totalTrackLimitReason,
      'nonContiguousReason': nonContiguousReason,
      'underrunReason': underrunReason,
      'checksumWindow0Hex': checksumWindow0Hex,
      'checksumWindow1Hex': checksumWindow1Hex,
      ...parsedMetrics,
    };

    return VGAudioGraphExportSessionSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      details: details,
      sessionCreateOk: sessionCreateOk,
      longTimelineAdmissionOk: longTimelineAdmissionOk,
      addEightTracksOk: addEightTracksOk,
      totalTrackLimitRejectOk: totalTrackLimitRejectOk,
      prepareBarrierOk: prepareBarrierOk,
      routedSourceCountOk: routedSourceCountOk,
      contiguousWindowOk: contiguousWindowOk,
      renderTwoWindowsOk: renderTwoWindowsOk,
      checksumNonZeroOk: checksumNonZeroOk,
      underrunFailClosedOk: underrunFailClosedOk,
      lifecycleDestroyIdempotentOk: lifecycleDestroyIdempotentOk,
      proofBoundaryOk: proofBoundaryOk,
      noProductionRouteSwapOk: noProductionRouteSwapOk,
      canonical: canonical,
      requestedTrackCount: requestedTrackCount,
      routedSourceCount: routedSourceCount,
      windowCount: windowCount,
      silentWindowCount: silentWindowCount,
      framesRendered: framesRendered,
      longTimelineFrames: longTimelineFrames,
      totalTrackLimitReason: totalTrackLimitReason,
      nonContiguousReason: nonContiguousReason,
      underrunReason: underrunReason,
      checksumWindow0Hex: checksumWindow0Hex,
      checksumWindow1Hex: checksumWindow1Hex,
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

  static VGAudioGraphExportSessionSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      'sessionCreateOk': false,
      'longTimelineAdmissionOk': false,
      'addEightTracksOk': false,
      'totalTrackLimitRejectOk': false,
      'prepareBarrierOk': false,
      'routedSourceCountOk': false,
      'contiguousWindowOk': false,
      'renderTwoWindowsOk': false,
      'checksumNonZeroOk': false,
      'underrunFailClosedOk': false,
      'lifecycleDestroyIdempotentOk': false,
      'proofBoundaryOk': false,
      'noProductionRouteSwapOk': false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'requestedTrackCount': 0,
      'routedSourceCount': 0,
      'windowCount': 0,
      'silentWindowCount': 0,
      'framesRendered': 0,
      'longTimelineFrames': 0,
      'totalTrackLimitReason': '',
      'nonContiguousReason': '',
      'underrunReason': '',
      'checksumWindow0Hex': '',
      'checksumWindow1Hex': '',
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGAudioGraphExportSessionSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      sessionCreateOk: false,
      longTimelineAdmissionOk: false,
      addEightTracksOk: false,
      totalTrackLimitRejectOk: false,
      prepareBarrierOk: false,
      routedSourceCountOk: false,
      contiguousWindowOk: false,
      renderTwoWindowsOk: false,
      checksumNonZeroOk: false,
      underrunFailClosedOk: false,
      lifecycleDestroyIdempotentOk: false,
      proofBoundaryOk: false,
      noProductionRouteSwapOk: false,
      canonical: false,
      requestedTrackCount: 0,
      routedSourceCount: 0,
      windowCount: 0,
      silentWindowCount: 0,
      framesRendered: 0,
      longTimelineFrames: 0,
      totalTrackLimitReason: '',
      nonContiguousReason: '',
      underrunReason: '',
      checksumWindow0Hex: '',
      checksumWindow1Hex: '',
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
    );
  }

  /// Invokes the Android True-DAG Phase 4 N-source node-owned ring audio graph
  /// export session diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation (defaults to 20 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAudioGraphExportSessionSmokeReport>
  runAndroidDagPhase4AudioGraphExportSessionSmoke({
    Duration timeout = const Duration(seconds: 20),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = await future.timeout(timeout);
      return VGAudioGraphExportSessionSmokeReport.fromMap(raw);
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
    return other is VGAudioGraphExportSessionSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.sessionCreateOk == sessionCreateOk &&
        other.longTimelineAdmissionOk == longTimelineAdmissionOk &&
        other.addEightTracksOk == addEightTracksOk &&
        other.totalTrackLimitRejectOk == totalTrackLimitRejectOk &&
        other.prepareBarrierOk == prepareBarrierOk &&
        other.routedSourceCountOk == routedSourceCountOk &&
        other.contiguousWindowOk == contiguousWindowOk &&
        other.renderTwoWindowsOk == renderTwoWindowsOk &&
        other.checksumNonZeroOk == checksumNonZeroOk &&
        other.underrunFailClosedOk == underrunFailClosedOk &&
        other.lifecycleDestroyIdempotentOk == lifecycleDestroyIdempotentOk &&
        other.proofBoundaryOk == proofBoundaryOk &&
        other.noProductionRouteSwapOk == noProductionRouteSwapOk &&
        other.canonical == canonical &&
        other.requestedTrackCount == requestedTrackCount &&
        other.routedSourceCount == routedSourceCount &&
        other.windowCount == windowCount &&
        other.silentWindowCount == silentWindowCount &&
        other.framesRendered == framesRendered &&
        other.longTimelineFrames == longTimelineFrames &&
        other.totalTrackLimitReason == totalTrackLimitReason &&
        other.nonContiguousReason == nonContiguousReason &&
        other.underrunReason == underrunReason &&
        other.checksumWindow0Hex == checksumWindow0Hex &&
        other.checksumWindow1Hex == checksumWindow1Hex &&
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
    sessionCreateOk,
    longTimelineAdmissionOk,
    addEightTracksOk,
    totalTrackLimitRejectOk,
    prepareBarrierOk,
    routedSourceCountOk,
    contiguousWindowOk,
    renderTwoWindowsOk,
    checksumNonZeroOk,
    underrunFailClosedOk,
    lifecycleDestroyIdempotentOk,
    proofBoundaryOk,
    noProductionRouteSwapOk,
    canonical,
    requestedTrackCount,
    routedSourceCount,
    windowCount,
    silentWindowCount,
    framesRendered,
    longTimelineFrames,
    totalTrackLimitReason,
    nonContiguousReason,
    underrunReason,
    checksumWindow0Hex,
    checksumWindow1Hex,
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
      'VGAudioGraphExportSessionSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'failureReason: $failureReason, '
      'sessionCreateOk: $sessionCreateOk, '
      'longTimelineAdmissionOk: $longTimelineAdmissionOk, '
      'addEightTracksOk: $addEightTracksOk, '
      'totalTrackLimitRejectOk: $totalTrackLimitRejectOk, '
      'prepareBarrierOk: $prepareBarrierOk, '
      'routedSourceCountOk: $routedSourceCountOk, '
      'contiguousWindowOk: $contiguousWindowOk, '
      'renderTwoWindowsOk: $renderTwoWindowsOk, '
      'checksumNonZeroOk: $checksumNonZeroOk, '
      'underrunFailClosedOk: $underrunFailClosedOk, '
      'lifecycleDestroyIdempotentOk: $lifecycleDestroyIdempotentOk, '
      'proofBoundaryOk: $proofBoundaryOk, '
      'noProductionRouteSwapOk: $noProductionRouteSwapOk, '
      'canonical: $canonical, '
      'requestedTrackCount: $requestedTrackCount, '
      'routedSourceCount: $routedSourceCount, '
      'windowCount: $windowCount, '
      'silentWindowCount: $silentWindowCount, '
      'framesRendered: $framesRendered, '
      'longTimelineFrames: $longTimelineFrames, '
      'totalTrackLimitReason: $totalTrackLimitReason, '
      'nonContiguousReason: $nonContiguousReason, '
      'underrunReason: $underrunReason, '
      'checksumWindow0Hex: $checksumWindow0Hex, '
      'checksumWindow1Hex: $checksumWindow1Hex, '
      'lastError: $lastError)';
}
