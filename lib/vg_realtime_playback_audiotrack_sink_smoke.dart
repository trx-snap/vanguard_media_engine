// vg_realtime_playback_audiotrack_sink_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-AUDIOTRACK-SINK (Y2): Android True-DAG Phase 4
// realtime playback AudioTrack sink diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimePlaybackAudioTrackSinkSmoke` MethodChannel route.
// Diagnostic-only - validates the VanguardRealtimePlaybackAudioTrackSink Kotlin adapter
// driven by the authoritative VanguardRealtimePlaybackTransportStateMachine (Y1),
// draining mixed PCM16 into a muted android.media.AudioTrack MODE_STREAM sink.
//
// Honest non-claims (Proof Boundary):
// muted_diagnostic_audiotrack_sink_only_synthetic_pcm_input_expected_from_y1_transport_no_mediacodec_no_mediaextractor_no_audio_focus_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimePlaybackAudioTrackSinkSmokeReport.runRealtimePlaybackAudioTrackSinkSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGRealtimePlaybackAudioTrackSinkSmokeReport {
  const VGRealtimePlaybackAudioTrackSinkSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.audioTrackInitOk,
    required this.mutedOutputOk,
    required this.transportCompletedOk,
    required this.checksumIdentityOk,
    required this.sinkWriteAccountingOk,
    required this.playbackHeadAdvancedOk,
    required this.audioTrackReleasedOk,
    required this.lifecycleOk,
    required this.canonical,
    required this.sampleRate,
    required this.channelCount,
    required this.maxFramesPerMix,
    required this.declaredFrameCount,
    required this.framesReadFromTransport,
    required this.framesWrittenToSink,
    required this.partialWriteCount,
    required this.zeroWriteCount,
    required this.playbackHeadFinal,
    required this.releaseCount,
    required this.kotlinSinkChecksumHex,
    required this.nativeDrainedChecksumHex,
    required this.transportState,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runRealtimePlaybackAudioTrackSinkSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'muted_diagnostic_audiotrack_sink_only_synthetic_pcm_input_expected_from_y1_transport_no_mediacodec_no_mediaextractor_no_audio_focus_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes';

  /// All required native lane keys that must be present and reported.
  static const List<String> requiredNativeLaneKeys = <String>[
    'audioTrackInitOk',
    'mutedOutputOk',
    'transportCompletedOk',
    'checksumIdentityOk',
    'sinkWriteAccountingOk',
    'playbackHeadAdvancedOk',
    'audioTrackReleasedOk',
    'lifecycleOk',
    'canonical',
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

  /// Whether AudioTrack initialized successfully.
  final bool audioTrackInitOk;

  /// Whether AudioTrack volume was set to 0.0 (muted).
  final bool mutedOutputOk;

  /// Whether transport state machine reached COMPLETED state.
  final bool transportCompletedOk;

  /// Whether Kotlin sink checksum matches native drained checksum.
  final bool checksumIdentityOk;

  /// Whether frames read from transport equal frames written to sink and equal declaredFrameCount.
  final bool sinkWriteAccountingOk;

  /// Whether playback head position advanced (> 0).
  final bool playbackHeadAdvancedOk;

  /// Whether AudioTrack was stopped and released with releaseCount == 1.
  final bool audioTrackReleasedOk;

  /// Whether full lifecycle clean up succeeded (releaseCount == 1).
  final bool lifecycleOk;

  /// Canonical pass indicator.
  final bool canonical;

  // ---- Metrics ------------------------------------------------------------

  final int sampleRate;
  final int channelCount;
  final int maxFramesPerMix;
  final int declaredFrameCount;
  final int framesReadFromTransport;
  final int framesWrittenToSink;
  final int partialWriteCount;
  final int zeroWriteCount;
  final int playbackHeadFinal;
  final int releaseCount;
  final String kotlinSinkChecksumHex;
  final String nativeDrainedChecksumHex;
  final String transportState;

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
    if (!audioTrackInitOk) return false;
    if (!mutedOutputOk) return false;
    if (!transportCompletedOk) return false;
    if (!checksumIdentityOk) return false;
    if (!sinkWriteAccountingOk) return false;
    if (!playbackHeadAdvancedOk) return false;
    if (!audioTrackReleasedOk) return false;
    if (!lifecycleOk) return false;
    if (!canonical) return false;
    if (releaseCount != 1) return false;
    if (framesReadFromTransport != declaredFrameCount ||
        framesWrittenToSink != declaredFrameCount ||
        framesReadFromTransport != framesWrittenToSink ||
        declaredFrameCount <= 0) {
      return false;
    }
    if (lastError.isNotEmpty && lastError != 'none' && lastError != 'null') {
      return false;
    }
    if (failureReason.isNotEmpty) return false;
    return true;
  }

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealtimePlaybackAudioTrackSinkSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGRealtimePlaybackAudioTrackSinkSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        nativeProofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        audioTrackInitOk: false,
        mutedOutputOk: false,
        transportCompletedOk: false,
        checksumIdentityOk: false,
        sinkWriteAccountingOk: false,
        playbackHeadAdvancedOk: false,
        audioTrackReleasedOk: false,
        lifecycleOk: false,
        canonical: false,
        sampleRate: 0,
        channelCount: 0,
        maxFramesPerMix: 0,
        declaredFrameCount: 0,
        framesReadFromTransport: 0,
        framesWrittenToSink: 0,
        partialWriteCount: 0,
        zeroWriteCount: 0,
        playbackHeadFinal: 0,
        releaseCount: 0,
        kotlinSinkChecksumHex: '',
        nativeDrainedChecksumHex: '',
        transportState: '',
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

    final audioTrackInitOk = parseBool('audioTrackInitOk');
    final mutedOutputOk = parseBool('mutedOutputOk');
    final transportCompletedOk = parseBool('transportCompletedOk');
    final checksumIdentityOk = parseBool('checksumIdentityOk');
    final sinkWriteAccountingOk = parseBool('sinkWriteAccountingOk');
    final playbackHeadAdvancedOk = parseBool('playbackHeadAdvancedOk');
    final audioTrackReleasedOk = parseBool('audioTrackReleasedOk');
    final lifecycleOk = parseBool('lifecycleOk');
    final canonical = parseBool('canonical', rawPass && missingLanes.isEmpty);

    final sampleRate = parseInt('sampleRate');
    final channelCount = parseInt('channelCount');
    final maxFramesPerMix = parseInt('maxFramesPerMix');
    final declaredFrameCount = parseInt('declaredFrameCount');
    final framesReadFromTransport = parseInt('framesReadFromTransport');
    final framesWrittenToSink = parseInt('framesWrittenToSink');
    final partialWriteCount = parseInt('partialWriteCount');
    final zeroWriteCount = parseInt('zeroWriteCount');
    final playbackHeadFinal = parseInt('playbackHeadFinal');
    final releaseCount = parseInt('releaseCount');
    final kotlinSinkChecksumHex = parseString('kotlinSinkChecksumHex');
    final nativeDrainedChecksumHex = parseString('nativeDrainedChecksumHex');
    final transportState = parseString('transportState');

    final hasValidProofBoundary =
        proofBoundary == proofBoundaryConstant &&
        (nativeProofBoundary.isEmpty ||
            nativeProofBoundary == proofBoundaryConstant);
    final hasValidPassMarker = rawMarker == passMarkerConstant;

    final allRequiredLanesTrue =
        audioTrackInitOk &&
        mutedOutputOk &&
        transportCompletedOk &&
        checksumIdentityOk &&
        sinkWriteAccountingOk &&
        playbackHeadAdvancedOk &&
        audioTrackReleasedOk &&
        lifecycleOk &&
        canonical;

    final allRequiredLanesPresent = missingLanes.isEmpty;

    final validFrameAccounting =
        framesReadFromTransport == declaredFrameCount &&
        framesWrittenToSink == declaredFrameCount &&
        framesReadFromTransport == framesWrittenToSink &&
        declaredFrameCount > 0;

    final validReleaseCount = releaseCount == 1;

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
        validFrameAccounting &&
        validReleaseCount &&
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
      } else if (!validFrameAccounting) {
        lastError = 'frame_accounting_mismatch';
        status = 'frame_accounting_mismatch';
      } else if (!validReleaseCount) {
        lastError = 'release_count_mismatch';
        status = 'release_count_mismatch';
      } else {
        lastError = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
        status = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      }
    }

    final finalLanes = <String, Object?>{
      'audioTrackInitOk': audioTrackInitOk,
      'mutedOutputOk': mutedOutputOk,
      'transportCompletedOk': transportCompletedOk,
      'checksumIdentityOk': checksumIdentityOk,
      'sinkWriteAccountingOk': sinkWriteAccountingOk,
      'playbackHeadAdvancedOk': playbackHeadAdvancedOk,
      'audioTrackReleasedOk': audioTrackReleasedOk,
      'lifecycleOk': lifecycleOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{
      'sampleRate': sampleRate,
      'channelCount': channelCount,
      'maxFramesPerMix': maxFramesPerMix,
      'declaredFrameCount': declaredFrameCount,
      'framesReadFromTransport': framesReadFromTransport,
      'framesWrittenToSink': framesWrittenToSink,
      'partialWriteCount': partialWriteCount,
      'zeroWriteCount': zeroWriteCount,
      'playbackHeadFinal': playbackHeadFinal,
      'releaseCount': releaseCount,
      'kotlinSinkChecksumHex': kotlinSinkChecksumHex,
      'nativeDrainedChecksumHex': nativeDrainedChecksumHex,
      'transportState': transportState,
      ...parsedMetrics,
    };

    return VGRealtimePlaybackAudioTrackSinkSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: failureReason,
      details: details,
      audioTrackInitOk: audioTrackInitOk,
      mutedOutputOk: mutedOutputOk,
      transportCompletedOk: transportCompletedOk,
      checksumIdentityOk: checksumIdentityOk,
      sinkWriteAccountingOk: sinkWriteAccountingOk,
      playbackHeadAdvancedOk: playbackHeadAdvancedOk,
      audioTrackReleasedOk: audioTrackReleasedOk,
      lifecycleOk: lifecycleOk,
      canonical: canonical,
      sampleRate: sampleRate,
      channelCount: channelCount,
      maxFramesPerMix: maxFramesPerMix,
      declaredFrameCount: declaredFrameCount,
      framesReadFromTransport: framesReadFromTransport,
      framesWrittenToSink: framesWrittenToSink,
      partialWriteCount: partialWriteCount,
      zeroWriteCount: zeroWriteCount,
      playbackHeadFinal: playbackHeadFinal,
      releaseCount: releaseCount,
      kotlinSinkChecksumHex: kotlinSinkChecksumHex,
      nativeDrainedChecksumHex: nativeDrainedChecksumHex,
      transportState: transportState,
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

  static VGRealtimePlaybackAudioTrackSinkSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      'audioTrackInitOk': false,
      'mutedOutputOk': false,
      'transportCompletedOk': false,
      'checksumIdentityOk': false,
      'sinkWriteAccountingOk': false,
      'playbackHeadAdvancedOk': false,
      'audioTrackReleasedOk': false,
      'lifecycleOk': false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'sampleRate': 0,
      'channelCount': 0,
      'maxFramesPerMix': 0,
      'declaredFrameCount': 0,
      'framesReadFromTransport': 0,
      'framesWrittenToSink': 0,
      'partialWriteCount': 0,
      'zeroWriteCount': 0,
      'playbackHeadFinal': 0,
      'releaseCount': 0,
      'kotlinSinkChecksumHex': '',
      'nativeDrainedChecksumHex': '',
      'transportState': '',
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGRealtimePlaybackAudioTrackSinkSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      nativeProofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      audioTrackInitOk: false,
      mutedOutputOk: false,
      transportCompletedOk: false,
      checksumIdentityOk: false,
      sinkWriteAccountingOk: false,
      playbackHeadAdvancedOk: false,
      audioTrackReleasedOk: false,
      lifecycleOk: false,
      canonical: false,
      sampleRate: 0,
      channelCount: 0,
      maxFramesPerMix: 0,
      declaredFrameCount: 0,
      framesReadFromTransport: 0,
      framesWrittenToSink: 0,
      partialWriteCount: 0,
      zeroWriteCount: 0,
      playbackHeadFinal: 0,
      releaseCount: 0,
      kotlinSinkChecksumHex: '',
      nativeDrainedChecksumHex: '',
      transportState: '',
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
    );
  }

  /// Invokes the Android True-DAG Phase 4 Realtime Playback AudioTrack Sink
  /// diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation (defaults to 20 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGRealtimePlaybackAudioTrackSinkSmokeReport>
  runRealtimePlaybackAudioTrackSinkSmoke({
    Duration timeout = const Duration(seconds: 20),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = await future.timeout(timeout);
      return VGRealtimePlaybackAudioTrackSinkSmokeReport.fromMap(raw);
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
    return other is VGRealtimePlaybackAudioTrackSinkSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.nativeProofBoundary == nativeProofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.audioTrackInitOk == audioTrackInitOk &&
        other.mutedOutputOk == mutedOutputOk &&
        other.transportCompletedOk == transportCompletedOk &&
        other.checksumIdentityOk == checksumIdentityOk &&
        other.sinkWriteAccountingOk == sinkWriteAccountingOk &&
        other.playbackHeadAdvancedOk == playbackHeadAdvancedOk &&
        other.audioTrackReleasedOk == audioTrackReleasedOk &&
        other.lifecycleOk == lifecycleOk &&
        other.canonical == canonical &&
        other.sampleRate == sampleRate &&
        other.channelCount == channelCount &&
        other.maxFramesPerMix == maxFramesPerMix &&
        other.declaredFrameCount == declaredFrameCount &&
        other.framesReadFromTransport == framesReadFromTransport &&
        other.framesWrittenToSink == framesWrittenToSink &&
        other.partialWriteCount == partialWriteCount &&
        other.zeroWriteCount == zeroWriteCount &&
        other.playbackHeadFinal == playbackHeadFinal &&
        other.releaseCount == releaseCount &&
        other.kotlinSinkChecksumHex == kotlinSinkChecksumHex &&
        other.nativeDrainedChecksumHex == nativeDrainedChecksumHex &&
        other.transportState == transportState &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    pass,
    status,
    marker,
    proofBoundary,
    nativeProofBoundary,
    failureReason,
    details,
    audioTrackInitOk,
    mutedOutputOk,
    transportCompletedOk,
    checksumIdentityOk,
    sinkWriteAccountingOk,
    playbackHeadAdvancedOk,
    audioTrackReleasedOk,
    lifecycleOk,
    canonical,
    sampleRate,
    channelCount,
    maxFramesPerMix,
    declaredFrameCount,
    framesReadFromTransport,
    framesWrittenToSink,
    partialWriteCount,
    zeroWriteCount,
    playbackHeadFinal,
    releaseCount,
    kotlinSinkChecksumHex,
    nativeDrainedChecksumHex,
    transportState,
    lastError,
  ]);

  @override
  String toString() =>
      'VGRealtimePlaybackAudioTrackSinkSmokeReport(pass: $pass, status: $status, '
      'marker: $marker, audioTrackInitOk: $audioTrackInitOk, '
      'mutedOutputOk: $mutedOutputOk, transportCompletedOk: $transportCompletedOk, '
      'checksumIdentityOk: $checksumIdentityOk, sinkWriteAccountingOk: $sinkWriteAccountingOk, '
      'playbackHeadAdvancedOk: $playbackHeadAdvancedOk, '
      'audioTrackReleasedOk: $audioTrackReleasedOk, lifecycleOk: $lifecycleOk, '
      'canonical: $canonical, releaseCount: $releaseCount, '
      'framesReadFromTransport: $framesReadFromTransport, '
      'framesWrittenToSink: $framesWrittenToSink, '
      'declaredFrameCount: $declaredFrameCount, lastError: $lastError)';
}
