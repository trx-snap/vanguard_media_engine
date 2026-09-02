// vg_realtime_playback_real_decoder_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER (Y5b): Android True-DAG Phase 4
// realtime playback real MediaExtractor/MediaCodec PCM16 decode to external ingest seam diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimePlaybackRealDecoderSmoke` MethodChannel route.
// Diagnostic-only - validates real MediaExtractor / MediaCodec synchronous
// PCM16 decode feeding into the Y5a external ingest seam across eight proof lanes:
//   1. Format probe & initialization (sampleRate, channelCount, PCM16)
//   2. Real decoder ingest & identity (pushed == drained == declared == Kotlin checksum)
//   3. Seek re-anchor (quiesce, flush, previous-sync seek, discard pre-target audio)
//   4. Ring-full / partial-write backpressure and remainder retry recovery
//   5. External underrun is nonterminal and resumes cleanly
//   6. EOS accounting (silence padding bounded <= 1.0s, truncation past declared end)
//   7. Stale generation rejection before JNI
//   8. Lifecycle dispose rejection & clean extractor/codec teardown
//
// Honest non-claims (Proof Boundary):
// realtime_playback_real_decoder_diagnostic_only_mediacodec_mediaextractor_streaming_pcm16_to_y5a_external_ingest_seam_generation_pinned_owner_thread_handoff_no_presentation_clock_no_av_sync_no_resample_no_downmix_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimePlaybackRealDecoderSmokeReport.runRealtimePlaybackRealDecoderSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGRealtimePlaybackRealDecoderSmokeReport {
  const VGRealtimePlaybackRealDecoderSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.realDecoderIngestOk,
    required this.seekReanchorOk,
    required this.backpressureRecoveryOk,
    required this.underrunToleranceOk,
    required this.eosAccountingOk,
    required this.staleGenerationRejectedOk,
    required this.lifecycleDisposeOk,
    required this.proofBoundaryOk,
    required this.canonical,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
    this.raw = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runRealtimePlaybackRealDecoderSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_REAL_DECODER_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_REAL_DECODER_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_REAL_DECODER_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_REAL_DECODER_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'realtime_playback_real_decoder_diagnostic_only_mediacodec_mediaextractor_streaming_pcm16_to_y5a_external_ingest_seam_generation_pinned_owner_thread_handoff_no_presentation_clock_no_av_sync_no_resample_no_downmix_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes';

  /// All required native gate keys that must be present and evaluate to true.
  static const List<String> requiredGateKeys = <String>[
    'formatProbeOk',
    'realDecoderIngestOk',
    'seekReanchorOk',
    'backpressureRecoveryOk',
    'underrunToleranceOk',
    'eosAccountingOk',
    'staleGenerationRejectedOk',
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

  /// Whether real decoder ingest and drain matched reference identity checksums and samples.
  final bool realDecoderIngestOk;

  /// Whether seek re-anchored expectedStartFrame, flushed codec, and rejected stale cursors.
  final bool seekReanchorOk;

  /// Whether ring-full / partial-write backpressure clamped correctly and recovered after drain.
  final bool backpressureRecoveryOk;

  /// Whether starving external ingest resulted in nonterminal underrun and resumed cleanly.
  final bool underrunToleranceOk;

  /// Whether EOS padding (bounded <= 1s) and truncation beyond declared duration completed accurately.
  final bool eosAccountingOk;

  /// Whether generation pinning rejected stale asynchronous postIngest calls before JNI.
  final bool staleGenerationRejectedOk;

  /// Whether state machine dispose rejected later ingest and extractor/codec were released cleanly.
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
      realDecoderIngestOk &&
      seekReanchorOk &&
      backpressureRecoveryOk &&
      underrunToleranceOk &&
      eosAccountingOk &&
      staleGenerationRejectedOk &&
      lifecycleDisposeOk;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealtimePlaybackRealDecoderSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGRealtimePlaybackRealDecoderSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        nativeProofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        formatProbeOk: false,
        realDecoderIngestOk: false,
        seekReanchorOk: false,
        backpressureRecoveryOk: false,
        underrunToleranceOk: false,
        eosAccountingOk: false,
        staleGenerationRejectedOk: false,
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
    final realDecoderIngestOk = parseBool('realDecoderIngestOk');
    final seekReanchorOk = parseBool('seekReanchorOk');
    final backpressureRecoveryOk = parseBool('backpressureRecoveryOk');
    final underrunToleranceOk = parseBool('underrunToleranceOk');
    final eosAccountingOk = parseBool('eosAccountingOk');
    final staleGenerationRejectedOk = parseBool('staleGenerationRejectedOk');
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
        realDecoderIngestOk &&
        seekReanchorOk &&
        backpressureRecoveryOk &&
        underrunToleranceOk &&
        eosAccountingOk &&
        staleGenerationRejectedOk &&
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
      'realDecoderIngestOk': realDecoderIngestOk,
      'seekReanchorOk': seekReanchorOk,
      'backpressureRecoveryOk': backpressureRecoveryOk,
      'underrunToleranceOk': underrunToleranceOk,
      'eosAccountingOk': eosAccountingOk,
      'staleGenerationRejectedOk': staleGenerationRejectedOk,
      'lifecycleDisposeOk': lifecycleDisposeOk,
      'proofBoundaryOk': proofBoundaryOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{...parsedMetrics};

    return VGRealtimePlaybackRealDecoderSmokeReport(
      pass: computedPass,
      status: finalStatus,
      marker: finalMarker,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: failureReason,
      details: details,
      formatProbeOk: formatProbeOk,
      realDecoderIngestOk: realDecoderIngestOk,
      seekReanchorOk: seekReanchorOk,
      backpressureRecoveryOk: backpressureRecoveryOk,
      underrunToleranceOk: underrunToleranceOk,
      eosAccountingOk: eosAccountingOk,
      staleGenerationRejectedOk: staleGenerationRejectedOk,
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

  static VGRealtimePlaybackRealDecoderSmokeReport _makeErrorFallbackReport({
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
    return VGRealtimePlaybackRealDecoderSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      nativeProofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      realDecoderIngestOk: false,
      seekReanchorOk: false,
      backpressureRecoveryOk: false,
      underrunToleranceOk: false,
      eosAccountingOk: false,
      staleGenerationRejectedOk: false,
      lifecycleDisposeOk: false,
      proofBoundaryOk: false,
      canonical: false,
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
      raw: 'pass=false;status=fail;marker=$failMarkerConstant;reason=$reason',
    );
  }

  /// Invokes the Android True-DAG Phase 4 Realtime Playback Real Decoder
  /// diagnostic smoke harness.
  ///
  /// [sourcePath] path to a media file with an audio track.
  /// [maxDurationSec] window duration in seconds (default 1.0).
  /// [seekTargetSec] seek target in seconds (default 0.35).
  /// [maxFramesPerMix] quantum mix size in frames (default 256).
  /// [deadlineMs] total deadline in milliseconds (default 30000).
  /// [timeout] optionally bounds the invocation (defaults to 35 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGRealtimePlaybackRealDecoderSmokeReport>
  runRealtimePlaybackRealDecoderSmoke({
    required String sourcePath,
    double maxDurationSec = 1.0,
    double seekTargetSec = 0.35,
    int maxFramesPerMix = 256,
    int deadlineMs = 30000,
    Duration timeout = const Duration(seconds: 35),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName, <String, dynamic>{
        'sourcePath': sourcePath,
        'maxDurationSec': maxDurationSec,
        'seekTargetSec': seekTargetSec,
        'maxFramesPerMix': maxFramesPerMix,
        'deadlineMs': deadlineMs,
      });
      final raw = await future.timeout(timeout);
      return VGRealtimePlaybackRealDecoderSmokeReport.fromMap(raw);
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
      'VGRealtimePlaybackRealDecoderSmokeReport(pass: $pass, status: $status, '
      'marker: $marker, isVerifiedPass: $isVerifiedPass, '
      'formatProbeOk: $formatProbeOk, realDecoderIngestOk: $realDecoderIngestOk, '
      'seekReanchorOk: $seekReanchorOk, backpressureRecoveryOk: $backpressureRecoveryOk, '
      'underrunToleranceOk: $underrunToleranceOk, eosAccountingOk: $eosAccountingOk, '
      'staleGenerationRejectedOk: $staleGenerationRejectedOk, lifecycleDisposeOk: $lifecycleDisposeOk, '
      'proofBoundaryOk: $proofBoundaryOk, canonical: $canonical, failureReason: $failureReason, '
      'lastError: $lastError)';
}
