// vg_realtime_playback_pipeline_integration_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-INTEGRATION-A (Y6a): Android True-DAG Phase 4
// realtime playback pipeline integration diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimePlaybackPipelineIntegrationSmoke` MethodChannel route.
// Diagnostic-only - validates real MediaExtractor / MediaCodec synchronous
// PCM16 decode feeding into the Y5a external ingest seam, native Y1 transport,
// and non-zero-gain AudioTrack sink across 15 required proof lanes:
//   1. formatProbeOk: format, duration, channel count and sample rate probed successfully
//   2. preRollOk: pre-roll while PREPARED until ring_full or declared end fits
//   3. realDecoderIngestOk: real decoder ingest and frame accounting
//   4. nonZeroGainSetOk: AudioTrack base volume set with non-zero gain
//   5. audioTrackInitOk: AudioTrack initialized in MODE_STREAM
//   6. sinkWriteAccountingOk: non-blocking AudioTrack write accounting and frame conservation
//   7. checksumIdentityOk: decoder, native pushed, native drained, and sink checksums match
//   8. backpressureObservedOk: backpressure ring full or partial write observed
//   9. underrunNonterminalOk: underruns and backpressure recorded, nonfatal
//  10. eosAccountingOk: EOS padding, truncation, and frame matching
//  11. playbackHeadAdvancedOk: playback head progress caught up
//  12. transportCompletedOk: transport reached COMPLETED state cleanly
//  13. threadOwnershipOk: strict thread ownership across decode, transport, and sink threads
//  14. cancellationOk: cancel probe verified with real threads
//  15. lifecycleDisposeOk: clean media and AudioTrack release, idempotent state machine dispose
//
// Honest non-claims (Proof Boundary):
// realtime_playback_pipeline_integration_a_diagnostic_only_real_mediacodec_mediaextractor_streaming_pcm16_to_y5a_external_ingest_seam_native_dag_transport_to_nonzero_gain_audiotrack_sink_base_gain_0_5_single_track_forward_playthrough_no_seek_no_pause_resume_no_interactive_controls_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_latency_drift_loudness_snr_claim_no_resample_no_downmix_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimePlaybackPipelineIntegrationSmokeReport.runRealtimePlaybackPipelineIntegrationSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGRealtimePlaybackPipelineIntegrationSmokeReport {
  const VGRealtimePlaybackPipelineIntegrationSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.preRollOk,
    required this.realDecoderIngestOk,
    required this.nonZeroGainSetOk,
    required this.audioTrackInitOk,
    required this.sinkWriteAccountingOk,
    required this.checksumIdentityOk,
    required this.backpressureObservedOk,
    required this.underrunNonterminalOk,
    required this.eosAccountingOk,
    required this.playbackHeadAdvancedOk,
    required this.transportCompletedOk,
    required this.threadOwnershipOk,
    required this.cancellationOk,
    required this.lifecycleDisposeOk,
    required this.proofBoundaryOk,
    required this.canonical,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
    this.raw = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runRealtimePlaybackPipelineIntegrationSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'realtime_playback_pipeline_integration_a_diagnostic_only_real_mediacodec_mediaextractor_streaming_pcm16_to_y5a_external_ingest_seam_native_dag_transport_to_nonzero_gain_audiotrack_sink_base_gain_0_5_single_track_forward_playthrough_no_seek_no_pause_resume_no_interactive_controls_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_latency_drift_loudness_snr_claim_no_resample_no_downmix_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes';

  /// All required native gate keys that must be present and evaluate to true.
  static const List<String> requiredGateKeys = <String>[
    'formatProbeOk',
    'preRollOk',
    'realDecoderIngestOk',
    'nonZeroGainSetOk',
    'audioTrackInitOk',
    'sinkWriteAccountingOk',
    'checksumIdentityOk',
    'backpressureObservedOk',
    'underrunNonterminalOk',
    'eosAccountingOk',
    'playbackHeadAdvancedOk',
    'transportCompletedOk',
    'threadOwnershipOk',
    'cancellationOk',
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

  /// Whether extractor probed format, channel count and sample rate successfully.
  final bool formatProbeOk;

  /// Whether pre-roll completed while PREPARED until ring_full or stream end.
  final bool preRollOk;

  /// Whether real decoder ingest and frame accounting completed.
  final bool realDecoderIngestOk;

  /// Whether AudioTrack base volume was set with non-zero gain.
  final bool nonZeroGainSetOk;

  /// Whether AudioTrack was initialized in MODE_STREAM.
  final bool audioTrackInitOk;

  /// Whether non-blocking AudioTrack write accounting and frame conservation held.
  final bool sinkWriteAccountingOk;

  /// Whether decoder, native pushed, native drained, and sink checksums matched identically.
  final bool checksumIdentityOk;

  /// Whether backpressure (ring_full or partial_write) was observed.
  final bool backpressureObservedOk;

  /// Whether underruns were nonfatal and recorded cleanly without error.
  final bool underrunNonterminalOk;

  /// Whether EOS padding, truncation, and frame accounting completed accurately.
  final bool eosAccountingOk;

  /// Whether playback head progression was caught up and advanced.
  final bool playbackHeadAdvancedOk;

  /// Whether transport completed into State.COMPLETED cleanly.
  final bool transportCompletedOk;

  /// Whether strict thread ownership across decode, transport, and sink threads held.
  final bool threadOwnershipOk;

  /// Whether cancel probe executed and cancelled mid-flight with clean teardown.
  final bool cancellationOk;

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
      realDecoderIngestOk &&
      nonZeroGainSetOk &&
      audioTrackInitOk &&
      sinkWriteAccountingOk &&
      checksumIdentityOk &&
      backpressureObservedOk &&
      underrunNonterminalOk &&
      eosAccountingOk &&
      playbackHeadAdvancedOk &&
      transportCompletedOk &&
      threadOwnershipOk &&
      cancellationOk &&
      lifecycleDisposeOk;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealtimePlaybackPipelineIntegrationSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGRealtimePlaybackPipelineIntegrationSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        nativeProofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        formatProbeOk: false,
        preRollOk: false,
        realDecoderIngestOk: false,
        nonZeroGainSetOk: false,
        audioTrackInitOk: false,
        sinkWriteAccountingOk: false,
        checksumIdentityOk: false,
        backpressureObservedOk: false,
        underrunNonterminalOk: false,
        eosAccountingOk: false,
        playbackHeadAdvancedOk: false,
        transportCompletedOk: false,
        threadOwnershipOk: false,
        cancellationOk: false,
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
    final realDecoderIngestOk = parseBool('realDecoderIngestOk');
    final nonZeroGainSetOk = parseBool('nonZeroGainSetOk');
    final audioTrackInitOk = parseBool('audioTrackInitOk');
    final sinkWriteAccountingOk = parseBool('sinkWriteAccountingOk');
    final checksumIdentityOk = parseBool('checksumIdentityOk');
    final backpressureObservedOk = parseBool('backpressureObservedOk');
    final underrunNonterminalOk = parseBool('underrunNonterminalOk');
    final eosAccountingOk = parseBool('eosAccountingOk');
    final playbackHeadAdvancedOk = parseBool('playbackHeadAdvancedOk');
    final transportCompletedOk = parseBool('transportCompletedOk');
    final threadOwnershipOk = parseBool('threadOwnershipOk');
    final cancellationOk = parseBool('cancellationOk');
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
        realDecoderIngestOk &&
        nonZeroGainSetOk &&
        audioTrackInitOk &&
        sinkWriteAccountingOk &&
        checksumIdentityOk &&
        backpressureObservedOk &&
        underrunNonterminalOk &&
        eosAccountingOk &&
        playbackHeadAdvancedOk &&
        transportCompletedOk &&
        threadOwnershipOk &&
        cancellationOk &&
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
      'realDecoderIngestOk': realDecoderIngestOk,
      'nonZeroGainSetOk': nonZeroGainSetOk,
      'audioTrackInitOk': audioTrackInitOk,
      'sinkWriteAccountingOk': sinkWriteAccountingOk,
      'checksumIdentityOk': checksumIdentityOk,
      'backpressureObservedOk': backpressureObservedOk,
      'underrunNonterminalOk': underrunNonterminalOk,
      'eosAccountingOk': eosAccountingOk,
      'playbackHeadAdvancedOk': playbackHeadAdvancedOk,
      'transportCompletedOk': transportCompletedOk,
      'threadOwnershipOk': threadOwnershipOk,
      'cancellationOk': cancellationOk,
      'lifecycleDisposeOk': lifecycleDisposeOk,
      'proofBoundaryOk': proofBoundaryOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{...parsedMetrics};

    return VGRealtimePlaybackPipelineIntegrationSmokeReport(
      pass: computedPass,
      status: finalStatus,
      marker: finalMarker,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: failureReason,
      details: details,
      formatProbeOk: formatProbeOk,
      preRollOk: preRollOk,
      realDecoderIngestOk: realDecoderIngestOk,
      nonZeroGainSetOk: nonZeroGainSetOk,
      audioTrackInitOk: audioTrackInitOk,
      sinkWriteAccountingOk: sinkWriteAccountingOk,
      checksumIdentityOk: checksumIdentityOk,
      backpressureObservedOk: backpressureObservedOk,
      underrunNonterminalOk: underrunNonterminalOk,
      eosAccountingOk: eosAccountingOk,
      playbackHeadAdvancedOk: playbackHeadAdvancedOk,
      transportCompletedOk: transportCompletedOk,
      threadOwnershipOk: threadOwnershipOk,
      cancellationOk: cancellationOk,
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

  static VGRealtimePlaybackPipelineIntegrationSmokeReport
  _makeErrorFallbackReport({
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
    return VGRealtimePlaybackPipelineIntegrationSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      nativeProofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      preRollOk: false,
      realDecoderIngestOk: false,
      nonZeroGainSetOk: false,
      audioTrackInitOk: false,
      sinkWriteAccountingOk: false,
      checksumIdentityOk: false,
      backpressureObservedOk: false,
      underrunNonterminalOk: false,
      eosAccountingOk: false,
      playbackHeadAdvancedOk: false,
      transportCompletedOk: false,
      threadOwnershipOk: false,
      cancellationOk: false,
      lifecycleDisposeOk: false,
      proofBoundaryOk: false,
      canonical: false,
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
      raw: 'pass=false;status=fail;marker=$failMarkerConstant;reason=$reason',
    );
  }

  /// Invokes the Android True-DAG Phase 4 Realtime Playback Pipeline Integration
  /// diagnostic smoke harness.
  ///
  /// [sourcePath] path to a media file with an audio track.
  /// [maxDurationSec] window duration in seconds (default 3.0).
  /// [maxFramesPerMix] quantum mix size in frames (default 256).
  /// [baseVolume] AudioTrack non-zero gain (default 0.5).
  /// [deadlineMs] total deadline in milliseconds (default 30000).
  /// [timeout] optionally bounds the invocation (defaults to 35 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGRealtimePlaybackPipelineIntegrationSmokeReport>
  runRealtimePlaybackPipelineIntegrationSmoke({
    required String sourcePath,
    double maxDurationSec = 3.0,
    int maxFramesPerMix = 256,
    double baseVolume = 0.5,
    int deadlineMs = 30000,
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
      });
      final raw = await future.timeout(timeout);
      return VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(raw);
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
      'VGRealtimePlaybackPipelineIntegrationSmokeReport(pass: $pass, status: $status, '
      'marker: $marker, isVerifiedPass: $isVerifiedPass, '
      'formatProbeOk: $formatProbeOk, preRollOk: $preRollOk, realDecoderIngestOk: $realDecoderIngestOk, '
      'nonZeroGainSetOk: $nonZeroGainSetOk, audioTrackInitOk: $audioTrackInitOk, '
      'sinkWriteAccountingOk: $sinkWriteAccountingOk, checksumIdentityOk: $checksumIdentityOk, '
      'backpressureObservedOk: $backpressureObservedOk, underrunNonterminalOk: $underrunNonterminalOk, '
      'eosAccountingOk: $eosAccountingOk, playbackHeadAdvancedOk: $playbackHeadAdvancedOk, '
      'transportCompletedOk: $transportCompletedOk, threadOwnershipOk: $threadOwnershipOk, '
      'cancellationOk: $cancellationOk, lifecycleDisposeOk: $lifecycleDisposeOk, '
      'proofBoundaryOk: $proofBoundaryOk, canonical: $canonical, failureReason: $failureReason, '
      'lastError: $lastError)';
}
