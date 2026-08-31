// vg_audio_mixbus_timeline_smoke.dart
// vanguard_media_engine - P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP: Android True-DAG Phase 4
// AudioMixBusNode timeline-aware per-frame volume envelope diagnostic smoke foundation
// (under P4-AUDIO-MIXBUS).
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AudioMixBusTimelineSmoke` MethodChannel route.
// Diagnostic-only - validates native vanguard::audio::AudioMixBusNode
// timeline-aware per-frame volume envelope evaluation, linear interpolation,
// parity with Kotlin AndroidAudioVolumeEnvelope math, static fade fallback,
// single quantization, floor PTS derivation, cursor reset, boundary checks,
// and rejection cases without scheduler wiring, production mixdown change,
// export reroute, or realtime sinks.
//
// Honest non-claims (Proof Boundary):
// native_audio_mix_bus_per_frame_volume_envelope_diagnostic_only_linear_interpolation_only_kotlin_android_audio_volume_envelope_parity_normalize_static_fade_and_evaluate_ported_to_cpp_node_owns_gain_math_caller_owns_window_origin_no_scheduler_wiring_no_production_mixdown_change_no_export_reroute_no_pass2_reroute_no_runtime_queue_no_backpressure_no_realtime_sink_no_threads_no_audio_track_no_aaudio_no_media_codec_no_file_io_no_streaming_no_cache_no_ios_no_product_no_editor_no_connects_app

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAudioMixBusTimelineSmokeReport.runAndroidDagPhase4AudioMixBusTimelineSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAudioMixBusTimelineSmokeReport {
  const VGAudioMixBusTimelineSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.envelopeNormalizationParityOk,
    required this.envelopeStaticFadePathParityOk,
    required this.envelopeForTrackFallbackParityOk,
    required this.envelopeEvaluationParityOk,
    required this.emptyEnvelopeSilenceParityOk,
    required this.subMillisecondHoldOk,
    required this.boundaryInclusivityOk,
    required this.mixGainNormalizationOk,
    required this.perFrameEnvelopeAppliedOk,
    required this.staticGainCompositionOk,
    required this.nullEnvelopeBackCompatOk,
    required this.singleQuantizationOk,
    required this.envelopeCursorMonotonicOk,
    required this.envelopeCursorResetPerCallOk,
    required this.floorPtsDerivationOk,
    required this.unsupportedInterpolationRejectOk,
    required this.keyframeCapRejectOk,
    required this.invalidEnvelopeRangeRejectOk,
    required this.invalidEnvelopeStartPtsRejectOk,
    required this.invalidEnvelopeGainRejectOk,
    required this.noPerMixAllocationOk,
    required this.schedulerUnchangedOk,
    required this.productionMixdownUntouchedOk,
    required this.lifecycleOk,
    required this.stackScoped,
    required this.canonical,
    required this.normalizedKeyframeCount,
    required this.staticFadeKeyframeCount,
    required this.evaluationSampleCount,
    required this.maxGainDiffScaled,
    required this.envelopeEvaluations,
    required this.framesMixed,
    required this.sampleRate,
    required this.channelCount,
    required this.maxFramesPerMix,
    required this.minEffectiveGain,
    required this.maxEffectiveGain,
    required this.staticGainChecksumHex,
    required this.envelopeMixChecksumHex,
    required this.nullEnvelopeChecksumHex,
    required this.baselineStaticChecksumHex,
    required this.prescaleApproxChecksumHex,
    required this.singleQuantChecksumHex,
    required this.roundPtsChecksumHex,
    required this.envelopeGainRejectVia,
    required this.timelineOwnershipHonesty,
    required this.lanes,
    required this.metrics,
    required this.raw,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidDagPhase4AudioMixBusTimelineSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_audio_mix_bus_per_frame_volume_envelope_diagnostic_only_linear_interpolation_only_kotlin_android_audio_volume_envelope_parity_normalize_static_fade_and_evaluate_ported_to_cpp_node_owns_gain_math_caller_owns_window_origin_no_scheduler_wiring_no_production_mixdown_change_no_export_reroute_no_pass2_reroute_no_runtime_queue_no_backpressure_no_realtime_sink_no_threads_no_audio_track_no_aaudio_no_media_codec_no_file_io_no_streaming_no_cache_no_ios_no_product_no_editor_no_connects_app';

  /// Minimum evaluation sample count required for analytic parity.
  static const int minEvaluationSamples = 2000;

  /// Maximum gain difference scaled bound (1e-9 error bound scaled by 1e15 = 1e6).
  static const int maxGainDiffScaledBound = 1000000;

  /// Expected sample rate for the diagnostic mix (48kHz).
  static const int expectedSampleRate = 48000;

  /// Expected channel count for the diagnostic mix (Stereo = 2).
  static const int expectedChannelCount = 2;

  /// All required native lane keys that must be present and reported.
  static const List<String> requiredNativeLaneKeys = <String>[
    'envelopeNormalizationParityOk',
    'envelopeStaticFadePathParityOk',
    'envelopeForTrackFallbackParityOk',
    'envelopeEvaluationParityOk',
    'emptyEnvelopeSilenceParityOk',
    'subMillisecondHoldOk',
    'boundaryInclusivityOk',
    'mixGainNormalizationOk',
    'perFrameEnvelopeAppliedOk',
    'staticGainCompositionOk',
    'nullEnvelopeBackCompatOk',
    'singleQuantizationOk',
    'envelopeCursorMonotonicOk',
    'envelopeCursorResetPerCallOk',
    'floorPtsDerivationOk',
    'unsupportedInterpolationRejectOk',
    'keyframeCapRejectOk',
    'invalidEnvelopeRangeRejectOk',
    'invalidEnvelopeStartPtsRejectOk',
    'invalidEnvelopeGainRejectOk',
    'noPerMixAllocationOk',
    'schedulerUnchangedOk',
    'productionMixdownUntouchedOk',
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

  // ---- Lanes (26 lanes: 25 native + 1 canonical) --------------------------

  /// Whether envelope normalization math matches Kotlin AndroidAudioVolumeEnvelope.
  final bool envelopeNormalizationParityOk;

  /// Whether static fade synthesis math matches Kotlin AndroidAudioVolumeEnvelope.
  final bool envelopeStaticFadePathParityOk;

  /// Whether forTrack fallback resolution matches Kotlin AndroidAudioVolumeEnvelope.
  final bool envelopeForTrackFallbackParityOk;

  /// Whether >=2000-sample envelope evaluation math matches Kotlin parity within 1e-9.
  final bool envelopeEvaluationParityOk;

  /// Whether empty envelope yields silence (gain 0.0) in parity with Kotlin.
  final bool emptyEnvelopeSilenceParityOk;

  /// Whether sub-millisecond keyframes obey hold rules in parity with Kotlin.
  final bool subMillisecondHoldOk;

  /// Whether envelope boundary inclusivity rules hold in parity with Kotlin.
  final bool boundaryInclusivityOk;

  /// Whether mixGain normalization to [0.0, 1.0] matches Kotlin parity.
  final bool mixGainNormalizationOk;

  /// Whether per-frame envelope application alters mixed PCM samples accurately.
  final bool perFrameEnvelopeAppliedOk;

  /// Whether static track gain and envelope gain compose multiplicatively.
  final bool staticGainCompositionOk;

  /// Whether null envelope provides bit-identical back-compat with baseline static gain.
  final bool nullEnvelopeBackCompatOk;

  /// Whether single-quantization per-sample math avoids pre-scale approximation error.
  final bool singleQuantizationOk;

  /// Whether envelope timeline cursor advances monotonically across frames.
  final bool envelopeCursorMonotonicOk;

  /// Whether envelope cursor resets cleanly per mix dispatch call.
  final bool envelopeCursorResetPerCallOk;

  /// Whether floor PTS derivation accurately aligns sample frames with envelope microseconds.
  final bool floorPtsDerivationOk;

  /// Whether unsupported non-linear interpolation modes are rejected before mix mutation.
  final bool unsupportedInterpolationRejectOk;

  /// Whether keyframe count exceeding capacity cap is rejected.
  final bool keyframeCapRejectOk;

  /// Whether invalid envelope time ranges (e.g. negative or inverted) are rejected.
  final bool invalidEnvelopeRangeRejectOk;

  /// Whether negative envelope start PTS is rejected.
  final bool invalidEnvelopeStartPtsRejectOk;

  /// Whether out-of-range envelope gain values (<0 or >1) are rejected.
  final bool invalidEnvelopeGainRejectOk;

  /// Whether no heap allocations occur during steady-state per-mix dispatch.
  final bool noPerMixAllocationOk;

  /// Source-level honesty lane: GraphAudioScheduler wiring remains unchanged.
  final bool schedulerUnchangedOk;

  /// Source-level honesty lane: production export chunk mixdown path is untouched.
  final bool productionMixdownUntouchedOk;

  /// Whether session lifecycle creation and cleanup are robust.
  final bool lifecycleOk;

  /// Whether JNI session and C++ node instances are strictly stack-scoped.
  final bool stackScoped;

  /// Canonical pass indicator.
  final bool canonical;

  // ---- Metrics (20 metrics) -----------------------------------------------

  /// Keyframe count of the normalized test envelope.
  final int normalizedKeyframeCount;

  /// Keyframe count of the static fade test envelope.
  final int staticFadeKeyframeCount;

  /// Total number of discrete points evaluated for analytic parity check.
  final int evaluationSampleCount;

  /// Maximum absolute difference between C++ and Kotlin gain scaled by 1e15.
  final int maxGainDiffScaled;

  /// Total number of envelope evaluations performed.
  final int envelopeEvaluations;

  /// Total PCM audio frames mixed during verification.
  final int framesMixed;

  /// Resolved sampling rate in Hz (48000).
  final int sampleRate;

  /// Resolved channel count (2).
  final int channelCount;

  /// Maximum frames rendered per mix dispatch cycle (256).
  final int maxFramesPerMix;

  /// Minimum effective gain observed across all frames.
  final double minEffectiveGain;

  /// Maximum effective gain observed across all frames.
  final double maxEffectiveGain;

  /// 64-bit hexadecimal checksum computed on static-gain-only mix output.
  final String staticGainChecksumHex;

  /// 64-bit hexadecimal checksum computed on envelope-mixed output.
  final String envelopeMixChecksumHex;

  /// 64-bit hexadecimal checksum computed on null-envelope mix output.
  final String nullEnvelopeChecksumHex;

  /// 64-bit hexadecimal checksum computed on baseline static mix output.
  final String baselineStaticChecksumHex;

  /// 64-bit hexadecimal checksum computed using pre-scale approximation math.
  final String prescaleApproxChecksumHex;

  /// 64-bit hexadecimal checksum computed using single-quantization math.
  final String singleQuantChecksumHex;

  /// 64-bit hexadecimal checksum computed with round PTS derivation.
  final String roundPtsChecksumHex;

  /// Identifier indicating reject path used for invalid envelope gain.
  final String envelopeGainRejectVia;

  /// Proof boundary token describing timeline ownership honesty.
  final String timelineOwnershipHonesty;

  // ---- Raw & Nested Maps --------------------------------------------------

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Map of raw string outputs emitted by native smoke execution.
  final Map<String, String> raw;

  /// Last error string from native execution, if any.
  final String lastError;

  // ---- Getters ------------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether [marker] matches the canonical pass marker constant.
  bool get hasPassMarker => marker == passMarkerConstant;

  /// Whether [marker] matches the canonical fail marker constant.
  bool get hasFailMarker => marker == failMarkerConstant;

  /// Whether null envelope checksum is identical to baseline static checksum (back-compat proof).
  bool get nullEnvelopeMatchesBaseline =>
      nullEnvelopeChecksumHex.isNotEmpty &&
      baselineStaticChecksumHex.isNotEmpty &&
      nullEnvelopeChecksumHex == baselineStaticChecksumHex;

  /// Whether evaluation sample count and maximum gain difference scaled meet required bounds.
  bool get analyticBoundsPass =>
      evaluationSampleCount >= minEvaluationSamples &&
      maxGainDiffScaled >= 0 &&
      maxGainDiffScaled <= maxGainDiffScaledBound;

  /// Whether observed effective gains are within valid [0.0, 1.0] bounds.
  bool get gainBoundsPass =>
      minEffectiveGain >= 0.0 &&
      maxEffectiveGain <= 1.0 &&
      minEffectiveGain <= maxEffectiveGain;

  /// Whether audio format properties match canonical test configuration.
  bool get audioFormatPass =>
      sampleRate == expectedSampleRate &&
      channelCount == expectedChannelCount &&
      framesMixed > 0;

  /// Whether all native diagnostic lanes passed according to the P4 AudioMixBus
  /// timeline ownership verification contract.
  bool get allNativeLanesPass {
    if (!pass) return false;
    if (status.toLowerCase() != 'pass') return false;
    if (!hasCanonicalProofBoundary) return false;
    if (!hasPassMarker) return false;
    if (!envelopeNormalizationParityOk) return false;
    if (!envelopeStaticFadePathParityOk) return false;
    if (!envelopeForTrackFallbackParityOk) return false;
    if (!envelopeEvaluationParityOk) return false;
    if (!emptyEnvelopeSilenceParityOk) return false;
    if (!subMillisecondHoldOk) return false;
    if (!boundaryInclusivityOk) return false;
    if (!mixGainNormalizationOk) return false;
    if (!perFrameEnvelopeAppliedOk) return false;
    if (!staticGainCompositionOk) return false;
    if (!nullEnvelopeBackCompatOk) return false;
    if (!singleQuantizationOk) return false;
    if (!envelopeCursorMonotonicOk) return false;
    if (!envelopeCursorResetPerCallOk) return false;
    if (!floorPtsDerivationOk) return false;
    if (!unsupportedInterpolationRejectOk) return false;
    if (!keyframeCapRejectOk) return false;
    if (!invalidEnvelopeRangeRejectOk) return false;
    if (!invalidEnvelopeStartPtsRejectOk) return false;
    if (!invalidEnvelopeGainRejectOk) return false;
    if (!noPerMixAllocationOk) return false;
    if (!schedulerUnchangedOk) return false;
    if (!productionMixdownUntouchedOk) return false;
    if (!lifecycleOk) return false;
    if (!stackScoped) return false;
    if (!canonical) return false;
    if (!analyticBoundsPass) return false;
    if (!gainBoundsPass) return false;
    if (!audioFormatPass) return false;
    if (!nullEnvelopeMatchesBaseline) return false;
    if (lastError.isNotEmpty && lastError != 'none' && lastError != 'null') {
      return false;
    }
    return true;
  }

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAudioMixBusTimelineSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAudioMixBusTimelineSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        envelopeNormalizationParityOk: false,
        envelopeStaticFadePathParityOk: false,
        envelopeForTrackFallbackParityOk: false,
        envelopeEvaluationParityOk: false,
        emptyEnvelopeSilenceParityOk: false,
        subMillisecondHoldOk: false,
        boundaryInclusivityOk: false,
        mixGainNormalizationOk: false,
        perFrameEnvelopeAppliedOk: false,
        staticGainCompositionOk: false,
        nullEnvelopeBackCompatOk: false,
        singleQuantizationOk: false,
        envelopeCursorMonotonicOk: false,
        envelopeCursorResetPerCallOk: false,
        floorPtsDerivationOk: false,
        unsupportedInterpolationRejectOk: false,
        keyframeCapRejectOk: false,
        invalidEnvelopeRangeRejectOk: false,
        invalidEnvelopeStartPtsRejectOk: false,
        invalidEnvelopeGainRejectOk: false,
        noPerMixAllocationOk: false,
        schedulerUnchangedOk: false,
        productionMixdownUntouchedOk: false,
        lifecycleOk: false,
        stackScoped: false,
        canonical: false,
        normalizedKeyframeCount: 0,
        staticFadeKeyframeCount: 0,
        evaluationSampleCount: 0,
        maxGainDiffScaled: 0,
        envelopeEvaluations: 0,
        framesMixed: 0,
        sampleRate: 0,
        channelCount: 0,
        maxFramesPerMix: 0,
        minEffectiveGain: 0.0,
        maxEffectiveGain: 0.0,
        staticGainChecksumHex: '',
        envelopeMixChecksumHex: '',
        nullEnvelopeChecksumHex: '',
        baselineStaticChecksumHex: '',
        prescaleApproxChecksumHex: '',
        singleQuantChecksumHex: '',
        roundPtsChecksumHex: '',
        envelopeGainRejectVia: '',
        timelineOwnershipHonesty: '',
        lanes: <String, Object?>{
          'envelopeNormalizationParityOk': false,
          'envelopeStaticFadePathParityOk': false,
          'envelopeForTrackFallbackParityOk': false,
          'envelopeEvaluationParityOk': false,
          'emptyEnvelopeSilenceParityOk': false,
          'subMillisecondHoldOk': false,
          'boundaryInclusivityOk': false,
          'mixGainNormalizationOk': false,
          'perFrameEnvelopeAppliedOk': false,
          'staticGainCompositionOk': false,
          'nullEnvelopeBackCompatOk': false,
          'singleQuantizationOk': false,
          'envelopeCursorMonotonicOk': false,
          'envelopeCursorResetPerCallOk': false,
          'floorPtsDerivationOk': false,
          'unsupportedInterpolationRejectOk': false,
          'keyframeCapRejectOk': false,
          'invalidEnvelopeRangeRejectOk': false,
          'invalidEnvelopeStartPtsRejectOk': false,
          'invalidEnvelopeGainRejectOk': false,
          'noPerMixAllocationOk': false,
          'schedulerUnchangedOk': false,
          'productionMixdownUntouchedOk': false,
          'lifecycleOk': false,
          'stackScoped': false,
          'canonical': false,
        },
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        raw: <String, String>{'reason': 'native_result_not_a_map'},
        lastError: 'native_result_not_a_map',
      );
    }

    final rawMapInput = raw['raw'];
    final parsedRaw = <String, String>{};
    if (rawMapInput is Map) {
      for (final entry in rawMapInput.entries) {
        final k = entry.key?.toString();
        final v = entry.value?.toString();
        if (k != null && v != null) {
          parsedRaw[k] = v;
        }
      }
    } else if (rawMapInput is String && rawMapInput.isNotEmpty) {
      for (final part in rawMapInput.split(';')) {
        final eq = part.indexOf('=');
        if (eq > 0) {
          final k = part.substring(0, eq).trim();
          final v = part.substring(eq + 1).trim();
          if (k.isNotEmpty) {
            parsedRaw[k] = v;
          }
        }
      }
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
      final v =
          parsedLanes[key] ?? raw[key] ?? parsedMetrics[key] ?? parsedRaw[key];
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
      final v =
          parsedMetrics[key] ?? raw[key] ?? parsedLanes[key] ?? parsedRaw[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    int parseInt(String key, [int defaultValue = 0]) {
      return parseIntStrict(key) ?? defaultValue;
    }

    double? parseDoubleStrict(String key) {
      final v =
          parsedMetrics[key] ?? raw[key] ?? parsedLanes[key] ?? parsedRaw[key];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v.trim());
      return null;
    }

    double parseDouble(String key, [double defaultValue = 0.0]) {
      return parseDoubleStrict(key) ?? defaultValue;
    }

    String parseString(String key, [String defaultValue = '']) {
      final v =
          raw[key] ?? parsedMetrics[key] ?? parsedLanes[key] ?? parsedRaw[key];
      if (v != null) return v.toString();
      return defaultValue;
    }

    final rawPass = parseBool(
      'pass',
      parsedRaw['status']?.toLowerCase() == 'pass',
    );
    final rawStatus = parseString('status', rawPass ? 'pass' : 'fail');
    final rawMarker = parseString(
      'marker',
      rawPass ? passMarkerConstant : failMarkerConstant,
    );
    final proofBoundary = parseString('proofBoundary');
    final failureReason = parseString(
      'failureReason',
      parsedRaw['reason'] ?? '',
    );
    final details = parseString('details');

    final missingLanes = <String>[];
    for (final laneKey in requiredNativeLaneKeys) {
      if (parseBoolStrict(laneKey) == null) {
        missingLanes.add(laneKey);
      }
    }

    final envelopeNormalizationParityOk = parseBool(
      'envelopeNormalizationParityOk',
    );
    final envelopeStaticFadePathParityOk = parseBool(
      'envelopeStaticFadePathParityOk',
    );
    final envelopeForTrackFallbackParityOk = parseBool(
      'envelopeForTrackFallbackParityOk',
    );
    final envelopeEvaluationParityOk = parseBool('envelopeEvaluationParityOk');
    final emptyEnvelopeSilenceParityOk = parseBool(
      'emptyEnvelopeSilenceParityOk',
    );
    final subMillisecondHoldOk = parseBool('subMillisecondHoldOk');
    final boundaryInclusivityOk = parseBool('boundaryInclusivityOk');
    final mixGainNormalizationOk = parseBool('mixGainNormalizationOk');
    final perFrameEnvelopeAppliedOk = parseBool('perFrameEnvelopeAppliedOk');
    final staticGainCompositionOk = parseBool('staticGainCompositionOk');
    final nullEnvelopeBackCompatOk = parseBool('nullEnvelopeBackCompatOk');
    final singleQuantizationOk = parseBool('singleQuantizationOk');
    final envelopeCursorMonotonicOk = parseBool('envelopeCursorMonotonicOk');
    final envelopeCursorResetPerCallOk = parseBool(
      'envelopeCursorResetPerCallOk',
    );
    final floorPtsDerivationOk = parseBool('floorPtsDerivationOk');
    final unsupportedInterpolationRejectOk = parseBool(
      'unsupportedInterpolationRejectOk',
    );
    final keyframeCapRejectOk = parseBool('keyframeCapRejectOk');
    final invalidEnvelopeRangeRejectOk = parseBool(
      'invalidEnvelopeRangeRejectOk',
    );
    final invalidEnvelopeStartPtsRejectOk = parseBool(
      'invalidEnvelopeStartPtsRejectOk',
    );
    final invalidEnvelopeGainRejectOk = parseBool(
      'invalidEnvelopeGainRejectOk',
    );
    final noPerMixAllocationOk = parseBool('noPerMixAllocationOk');
    final schedulerUnchangedOk = parseBool('schedulerUnchangedOk');
    final productionMixdownUntouchedOk = parseBool(
      'productionMixdownUntouchedOk',
    );
    final lifecycleOk = parseBool('lifecycleOk');
    final stackScoped = parseBool('stackScoped');
    final canonical = parseBool('canonical', rawPass && missingLanes.isEmpty);

    final normalizedKeyframeCount = parseInt('normalizedKeyframeCount');
    final staticFadeKeyframeCount = parseInt('staticFadeKeyframeCount');
    final evaluationSampleCount = parseInt('evaluationSampleCount');
    final maxGainDiffScaled = parseInt('maxGainDiffScaled');
    final envelopeEvaluations = parseInt('envelopeEvaluations');
    final framesMixed = parseInt('framesMixed');
    final sampleRate = parseInt('sampleRate');
    final channelCount = parseInt('channelCount');
    final maxFramesPerMix = parseInt('maxFramesPerMix', 256);

    final minEffectiveGain = parseDouble('minEffectiveGain');
    final maxEffectiveGain = parseDouble('maxEffectiveGain');

    final staticGainChecksumHex = parseString('staticGainChecksumHex');
    final envelopeMixChecksumHex = parseString('envelopeMixChecksumHex');
    final nullEnvelopeChecksumHex = parseString('nullEnvelopeChecksumHex');
    final baselineStaticChecksumHex = parseString('baselineStaticChecksumHex');
    final prescaleApproxChecksumHex = parseString('prescaleApproxChecksumHex');
    final singleQuantChecksumHex = parseString('singleQuantChecksumHex');
    final roundPtsChecksumHex = parseString('roundPtsChecksumHex');
    final envelopeGainRejectVia = parseString('envelopeGainRejectVia');
    final timelineOwnershipHonesty = parseString('timelineOwnershipHonesty');

    final hasValidProofBoundary = proofBoundary == proofBoundaryConstant;
    final hasValidPassMarker = rawMarker == passMarkerConstant;

    final allRequiredLanesTrue =
        envelopeNormalizationParityOk &&
        envelopeStaticFadePathParityOk &&
        envelopeForTrackFallbackParityOk &&
        envelopeEvaluationParityOk &&
        emptyEnvelopeSilenceParityOk &&
        subMillisecondHoldOk &&
        boundaryInclusivityOk &&
        mixGainNormalizationOk &&
        perFrameEnvelopeAppliedOk &&
        staticGainCompositionOk &&
        nullEnvelopeBackCompatOk &&
        singleQuantizationOk &&
        envelopeCursorMonotonicOk &&
        envelopeCursorResetPerCallOk &&
        floorPtsDerivationOk &&
        unsupportedInterpolationRejectOk &&
        keyframeCapRejectOk &&
        invalidEnvelopeRangeRejectOk &&
        invalidEnvelopeStartPtsRejectOk &&
        invalidEnvelopeGainRejectOk &&
        noPerMixAllocationOk &&
        schedulerUnchangedOk &&
        productionMixdownUntouchedOk &&
        lifecycleOk &&
        stackScoped &&
        canonical;

    final allRequiredLanesPresent = missingLanes.isEmpty;

    final boundsValid =
        evaluationSampleCount >= minEvaluationSamples &&
        maxGainDiffScaled >= 0 &&
        maxGainDiffScaled <= maxGainDiffScaledBound &&
        framesMixed > 0 &&
        sampleRate == expectedSampleRate &&
        channelCount == expectedChannelCount &&
        minEffectiveGain >= 0.0 &&
        maxEffectiveGain <= 1.0 &&
        minEffectiveGain <= maxEffectiveGain;

    final checksumsValid =
        nullEnvelopeChecksumHex.isNotEmpty &&
        baselineStaticChecksumHex.isNotEmpty &&
        nullEnvelopeChecksumHex == baselineStaticChecksumHex;

    final pass =
        rawPass &&
        rawStatus.toLowerCase() == 'pass' &&
        hasValidPassMarker &&
        hasValidProofBoundary &&
        allRequiredLanesPresent &&
        allRequiredLanesTrue &&
        boundsValid &&
        checksumsValid;

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
      } else if (!allRequiredLanesPresent) {
        lastError = 'missing_lane_${missingLanes.first}';
        status = 'missing_lane';
      } else if (!allRequiredLanesTrue) {
        lastError = 'lane_failed';
        status = 'lane_failed';
      } else if (evaluationSampleCount < minEvaluationSamples) {
        lastError = 'evaluation_sample_count_below_minimum';
        status = 'evaluation_sample_count_below_minimum';
      } else if (maxGainDiffScaled > maxGainDiffScaledBound ||
          maxGainDiffScaled < 0) {
        lastError = 'analytic_parity_bound_exceeded';
        status = 'analytic_parity_bound_exceeded';
      } else if (framesMixed <= 0) {
        lastError = 'no_frames_mixed';
        status = 'no_frames_mixed';
      } else if (sampleRate != expectedSampleRate ||
          channelCount != expectedChannelCount) {
        lastError = 'invalid_audio_format';
        status = 'invalid_audio_format';
      } else if (minEffectiveGain < 0.0 ||
          maxEffectiveGain > 1.0 ||
          minEffectiveGain > maxEffectiveGain) {
        lastError = 'gain_bounds_exceeded';
        status = 'gain_bounds_exceeded';
      } else if (!checksumsValid) {
        lastError = 'null_envelope_checksum_mismatch';
        status = 'null_envelope_checksum_mismatch';
      } else {
        lastError = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
        status = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      }
    }

    final finalLanes = <String, Object?>{
      'envelopeNormalizationParityOk': envelopeNormalizationParityOk,
      'envelopeStaticFadePathParityOk': envelopeStaticFadePathParityOk,
      'envelopeForTrackFallbackParityOk': envelopeForTrackFallbackParityOk,
      'envelopeEvaluationParityOk': envelopeEvaluationParityOk,
      'emptyEnvelopeSilenceParityOk': emptyEnvelopeSilenceParityOk,
      'subMillisecondHoldOk': subMillisecondHoldOk,
      'boundaryInclusivityOk': boundaryInclusivityOk,
      'mixGainNormalizationOk': mixGainNormalizationOk,
      'perFrameEnvelopeAppliedOk': perFrameEnvelopeAppliedOk,
      'staticGainCompositionOk': staticGainCompositionOk,
      'nullEnvelopeBackCompatOk': nullEnvelopeBackCompatOk,
      'singleQuantizationOk': singleQuantizationOk,
      'envelopeCursorMonotonicOk': envelopeCursorMonotonicOk,
      'envelopeCursorResetPerCallOk': envelopeCursorResetPerCallOk,
      'floorPtsDerivationOk': floorPtsDerivationOk,
      'unsupportedInterpolationRejectOk': unsupportedInterpolationRejectOk,
      'keyframeCapRejectOk': keyframeCapRejectOk,
      'invalidEnvelopeRangeRejectOk': invalidEnvelopeRangeRejectOk,
      'invalidEnvelopeStartPtsRejectOk': invalidEnvelopeStartPtsRejectOk,
      'invalidEnvelopeGainRejectOk': invalidEnvelopeGainRejectOk,
      'noPerMixAllocationOk': noPerMixAllocationOk,
      'schedulerUnchangedOk': schedulerUnchangedOk,
      'productionMixdownUntouchedOk': productionMixdownUntouchedOk,
      'lifecycleOk': lifecycleOk,
      'stackScoped': stackScoped,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{
      'normalizedKeyframeCount': normalizedKeyframeCount,
      'staticFadeKeyframeCount': staticFadeKeyframeCount,
      'evaluationSampleCount': evaluationSampleCount,
      'maxGainDiffScaled': maxGainDiffScaled,
      'envelopeEvaluations': envelopeEvaluations,
      'framesMixed': framesMixed,
      'sampleRate': sampleRate,
      'channelCount': channelCount,
      'maxFramesPerMix': maxFramesPerMix,
      'minEffectiveGain': minEffectiveGain,
      'maxEffectiveGain': maxEffectiveGain,
      'staticGainChecksumHex': staticGainChecksumHex,
      'envelopeMixChecksumHex': envelopeMixChecksumHex,
      'nullEnvelopeChecksumHex': nullEnvelopeChecksumHex,
      'baselineStaticChecksumHex': baselineStaticChecksumHex,
      'prescaleApproxChecksumHex': prescaleApproxChecksumHex,
      'singleQuantChecksumHex': singleQuantChecksumHex,
      'roundPtsChecksumHex': roundPtsChecksumHex,
      'envelopeGainRejectVia': envelopeGainRejectVia,
      'timelineOwnershipHonesty': timelineOwnershipHonesty,
      ...parsedMetrics,
    };

    return VGAudioMixBusTimelineSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      details: details,
      envelopeNormalizationParityOk: envelopeNormalizationParityOk,
      envelopeStaticFadePathParityOk: envelopeStaticFadePathParityOk,
      envelopeForTrackFallbackParityOk: envelopeForTrackFallbackParityOk,
      envelopeEvaluationParityOk: envelopeEvaluationParityOk,
      emptyEnvelopeSilenceParityOk: emptyEnvelopeSilenceParityOk,
      subMillisecondHoldOk: subMillisecondHoldOk,
      boundaryInclusivityOk: boundaryInclusivityOk,
      mixGainNormalizationOk: mixGainNormalizationOk,
      perFrameEnvelopeAppliedOk: perFrameEnvelopeAppliedOk,
      staticGainCompositionOk: staticGainCompositionOk,
      nullEnvelopeBackCompatOk: nullEnvelopeBackCompatOk,
      singleQuantizationOk: singleQuantizationOk,
      envelopeCursorMonotonicOk: envelopeCursorMonotonicOk,
      envelopeCursorResetPerCallOk: envelopeCursorResetPerCallOk,
      floorPtsDerivationOk: floorPtsDerivationOk,
      unsupportedInterpolationRejectOk: unsupportedInterpolationRejectOk,
      keyframeCapRejectOk: keyframeCapRejectOk,
      invalidEnvelopeRangeRejectOk: invalidEnvelopeRangeRejectOk,
      invalidEnvelopeStartPtsRejectOk: invalidEnvelopeStartPtsRejectOk,
      invalidEnvelopeGainRejectOk: invalidEnvelopeGainRejectOk,
      noPerMixAllocationOk: noPerMixAllocationOk,
      schedulerUnchangedOk: schedulerUnchangedOk,
      productionMixdownUntouchedOk: productionMixdownUntouchedOk,
      lifecycleOk: lifecycleOk,
      stackScoped: stackScoped,
      canonical: canonical,
      normalizedKeyframeCount: normalizedKeyframeCount,
      staticFadeKeyframeCount: staticFadeKeyframeCount,
      evaluationSampleCount: evaluationSampleCount,
      maxGainDiffScaled: maxGainDiffScaled,
      envelopeEvaluations: envelopeEvaluations,
      framesMixed: framesMixed,
      sampleRate: sampleRate,
      channelCount: channelCount,
      maxFramesPerMix: maxFramesPerMix,
      minEffectiveGain: minEffectiveGain,
      maxEffectiveGain: maxEffectiveGain,
      staticGainChecksumHex: staticGainChecksumHex,
      envelopeMixChecksumHex: envelopeMixChecksumHex,
      nullEnvelopeChecksumHex: nullEnvelopeChecksumHex,
      baselineStaticChecksumHex: baselineStaticChecksumHex,
      prescaleApproxChecksumHex: prescaleApproxChecksumHex,
      singleQuantChecksumHex: singleQuantChecksumHex,
      roundPtsChecksumHex: roundPtsChecksumHex,
      envelopeGainRejectVia: envelopeGainRejectVia,
      timelineOwnershipHonesty: timelineOwnershipHonesty,
      lanes: Map<String, Object?>.unmodifiable(finalLanes),
      metrics: Map<String, Object?>.unmodifiable(finalMetrics),
      raw: Map<String, String>.unmodifiable(parsedRaw),
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
      'raw': Map<String, String>.from(raw),
      'lastError': lastError,
    };
  }

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static VGAudioMixBusTimelineSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      'envelopeNormalizationParityOk': false,
      'envelopeStaticFadePathParityOk': false,
      'envelopeForTrackFallbackParityOk': false,
      'envelopeEvaluationParityOk': false,
      'emptyEnvelopeSilenceParityOk': false,
      'subMillisecondHoldOk': false,
      'boundaryInclusivityOk': false,
      'mixGainNormalizationOk': false,
      'perFrameEnvelopeAppliedOk': false,
      'staticGainCompositionOk': false,
      'nullEnvelopeBackCompatOk': false,
      'singleQuantizationOk': false,
      'envelopeCursorMonotonicOk': false,
      'envelopeCursorResetPerCallOk': false,
      'floorPtsDerivationOk': false,
      'unsupportedInterpolationRejectOk': false,
      'keyframeCapRejectOk': false,
      'invalidEnvelopeRangeRejectOk': false,
      'invalidEnvelopeStartPtsRejectOk': false,
      'invalidEnvelopeGainRejectOk': false,
      'noPerMixAllocationOk': false,
      'schedulerUnchangedOk': false,
      'productionMixdownUntouchedOk': false,
      'lifecycleOk': false,
      'stackScoped': false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'normalizedKeyframeCount': 0,
      'staticFadeKeyframeCount': 0,
      'evaluationSampleCount': 0,
      'maxGainDiffScaled': 0,
      'envelopeEvaluations': 0,
      'framesMixed': 0,
      'sampleRate': 0,
      'channelCount': 0,
      'maxFramesPerMix': 0,
      'minEffectiveGain': 0.0,
      'maxEffectiveGain': 0.0,
      'staticGainChecksumHex': '',
      'envelopeMixChecksumHex': '',
      'nullEnvelopeChecksumHex': '',
      'baselineStaticChecksumHex': '',
      'prescaleApproxChecksumHex': '',
      'singleQuantChecksumHex': '',
      'roundPtsChecksumHex': '',
      'envelopeGainRejectVia': '',
      'timelineOwnershipHonesty': '',
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGAudioMixBusTimelineSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      envelopeNormalizationParityOk: false,
      envelopeStaticFadePathParityOk: false,
      envelopeForTrackFallbackParityOk: false,
      envelopeEvaluationParityOk: false,
      emptyEnvelopeSilenceParityOk: false,
      subMillisecondHoldOk: false,
      boundaryInclusivityOk: false,
      mixGainNormalizationOk: false,
      perFrameEnvelopeAppliedOk: false,
      staticGainCompositionOk: false,
      nullEnvelopeBackCompatOk: false,
      singleQuantizationOk: false,
      envelopeCursorMonotonicOk: false,
      envelopeCursorResetPerCallOk: false,
      floorPtsDerivationOk: false,
      unsupportedInterpolationRejectOk: false,
      keyframeCapRejectOk: false,
      invalidEnvelopeRangeRejectOk: false,
      invalidEnvelopeStartPtsRejectOk: false,
      invalidEnvelopeGainRejectOk: false,
      noPerMixAllocationOk: false,
      schedulerUnchangedOk: false,
      productionMixdownUntouchedOk: false,
      lifecycleOk: false,
      stackScoped: false,
      canonical: false,
      normalizedKeyframeCount: 0,
      staticFadeKeyframeCount: 0,
      evaluationSampleCount: 0,
      maxGainDiffScaled: 0,
      envelopeEvaluations: 0,
      framesMixed: 0,
      sampleRate: 0,
      channelCount: 0,
      maxFramesPerMix: 0,
      minEffectiveGain: 0.0,
      maxEffectiveGain: 0.0,
      staticGainChecksumHex: '',
      envelopeMixChecksumHex: '',
      nullEnvelopeChecksumHex: '',
      baselineStaticChecksumHex: '',
      prescaleApproxChecksumHex: '',
      singleQuantChecksumHex: '',
      roundPtsChecksumHex: '',
      envelopeGainRejectVia: '',
      timelineOwnershipHonesty: '',
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      raw: Map<String, String>.unmodifiable(<String, String>{
        'status': 'FAIL',
        'reason': reason,
      }),
      lastError: lastError,
    );
  }

  /// Invokes the Android True-DAG Phase 4 AudioMixBus timeline-aware per-frame volume
  /// envelope diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation (defaults to 20 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAudioMixBusTimelineSmokeReport>
  runAndroidDagPhase4AudioMixBusTimelineSmoke({
    Duration timeout = const Duration(seconds: 20),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = await future.timeout(timeout);
      return VGAudioMixBusTimelineSmokeReport.fromMap(raw);
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
    return other is VGAudioMixBusTimelineSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.envelopeNormalizationParityOk == envelopeNormalizationParityOk &&
        other.envelopeStaticFadePathParityOk ==
            envelopeStaticFadePathParityOk &&
        other.envelopeForTrackFallbackParityOk ==
            envelopeForTrackFallbackParityOk &&
        other.envelopeEvaluationParityOk == envelopeEvaluationParityOk &&
        other.emptyEnvelopeSilenceParityOk == emptyEnvelopeSilenceParityOk &&
        other.subMillisecondHoldOk == subMillisecondHoldOk &&
        other.boundaryInclusivityOk == boundaryInclusivityOk &&
        other.mixGainNormalizationOk == mixGainNormalizationOk &&
        other.perFrameEnvelopeAppliedOk == perFrameEnvelopeAppliedOk &&
        other.staticGainCompositionOk == staticGainCompositionOk &&
        other.nullEnvelopeBackCompatOk == nullEnvelopeBackCompatOk &&
        other.singleQuantizationOk == singleQuantizationOk &&
        other.envelopeCursorMonotonicOk == envelopeCursorMonotonicOk &&
        other.envelopeCursorResetPerCallOk == envelopeCursorResetPerCallOk &&
        other.floorPtsDerivationOk == floorPtsDerivationOk &&
        other.unsupportedInterpolationRejectOk ==
            unsupportedInterpolationRejectOk &&
        other.keyframeCapRejectOk == keyframeCapRejectOk &&
        other.invalidEnvelopeRangeRejectOk == invalidEnvelopeRangeRejectOk &&
        other.invalidEnvelopeStartPtsRejectOk ==
            invalidEnvelopeStartPtsRejectOk &&
        other.invalidEnvelopeGainRejectOk == invalidEnvelopeGainRejectOk &&
        other.noPerMixAllocationOk == noPerMixAllocationOk &&
        other.schedulerUnchangedOk == schedulerUnchangedOk &&
        other.productionMixdownUntouchedOk == productionMixdownUntouchedOk &&
        other.lifecycleOk == lifecycleOk &&
        other.stackScoped == stackScoped &&
        other.canonical == canonical &&
        other.normalizedKeyframeCount == normalizedKeyframeCount &&
        other.staticFadeKeyframeCount == staticFadeKeyframeCount &&
        other.evaluationSampleCount == evaluationSampleCount &&
        other.maxGainDiffScaled == maxGainDiffScaled &&
        other.envelopeEvaluations == envelopeEvaluations &&
        other.framesMixed == framesMixed &&
        other.sampleRate == sampleRate &&
        other.channelCount == channelCount &&
        other.maxFramesPerMix == maxFramesPerMix &&
        other.minEffectiveGain == minEffectiveGain &&
        other.maxEffectiveGain == maxEffectiveGain &&
        other.staticGainChecksumHex == staticGainChecksumHex &&
        other.envelopeMixChecksumHex == envelopeMixChecksumHex &&
        other.nullEnvelopeChecksumHex == nullEnvelopeChecksumHex &&
        other.baselineStaticChecksumHex == baselineStaticChecksumHex &&
        other.prescaleApproxChecksumHex == prescaleApproxChecksumHex &&
        other.singleQuantChecksumHex == singleQuantChecksumHex &&
        other.roundPtsChecksumHex == roundPtsChecksumHex &&
        other.envelopeGainRejectVia == envelopeGainRejectVia &&
        other.timelineOwnershipHonesty == timelineOwnershipHonesty &&
        mapEquals(other.lanes, lanes) &&
        mapEquals(other.metrics, metrics) &&
        mapEquals(other.raw, raw) &&
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
    envelopeNormalizationParityOk,
    envelopeStaticFadePathParityOk,
    envelopeForTrackFallbackParityOk,
    envelopeEvaluationParityOk,
    emptyEnvelopeSilenceParityOk,
    subMillisecondHoldOk,
    boundaryInclusivityOk,
    mixGainNormalizationOk,
    perFrameEnvelopeAppliedOk,
    staticGainCompositionOk,
    nullEnvelopeBackCompatOk,
    singleQuantizationOk,
    envelopeCursorMonotonicOk,
    envelopeCursorResetPerCallOk,
    floorPtsDerivationOk,
    unsupportedInterpolationRejectOk,
    keyframeCapRejectOk,
    invalidEnvelopeRangeRejectOk,
    invalidEnvelopeStartPtsRejectOk,
    invalidEnvelopeGainRejectOk,
    noPerMixAllocationOk,
    schedulerUnchangedOk,
    productionMixdownUntouchedOk,
    lifecycleOk,
    stackScoped,
    canonical,
    normalizedKeyframeCount,
    staticFadeKeyframeCount,
    evaluationSampleCount,
    maxGainDiffScaled,
    envelopeEvaluations,
    framesMixed,
    sampleRate,
    channelCount,
    maxFramesPerMix,
    minEffectiveGain,
    maxEffectiveGain,
    staticGainChecksumHex,
    envelopeMixChecksumHex,
    nullEnvelopeChecksumHex,
    baselineStaticChecksumHex,
    prescaleApproxChecksumHex,
    singleQuantChecksumHex,
    roundPtsChecksumHex,
    envelopeGainRejectVia,
    timelineOwnershipHonesty,
    _stableMapHash(lanes),
    _stableMapHash(metrics),
    _stableMapHash(raw),
    lastError,
  ]);

  static int _stableMapHash(Map<dynamic, dynamic> map) {
    final sortedKeys = map.keys.map((k) => k.toString()).toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGAudioMixBusTimelineSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'envelopeNormalizationParityOk: $envelopeNormalizationParityOk, '
      'envelopeStaticFadePathParityOk: $envelopeStaticFadePathParityOk, '
      'envelopeForTrackFallbackParityOk: $envelopeForTrackFallbackParityOk, '
      'envelopeEvaluationParityOk: $envelopeEvaluationParityOk, '
      'emptyEnvelopeSilenceParityOk: $emptyEnvelopeSilenceParityOk, '
      'subMillisecondHoldOk: $subMillisecondHoldOk, '
      'boundaryInclusivityOk: $boundaryInclusivityOk, '
      'mixGainNormalizationOk: $mixGainNormalizationOk, '
      'perFrameEnvelopeAppliedOk: $perFrameEnvelopeAppliedOk, '
      'staticGainCompositionOk: $staticGainCompositionOk, '
      'nullEnvelopeBackCompatOk: $nullEnvelopeBackCompatOk, '
      'singleQuantizationOk: $singleQuantizationOk, '
      'envelopeCursorMonotonicOk: $envelopeCursorMonotonicOk, '
      'envelopeCursorResetPerCallOk: $envelopeCursorResetPerCallOk, '
      'floorPtsDerivationOk: $floorPtsDerivationOk, '
      'unsupportedInterpolationRejectOk: $unsupportedInterpolationRejectOk, '
      'keyframeCapRejectOk: $keyframeCapRejectOk, '
      'invalidEnvelopeRangeRejectOk: $invalidEnvelopeRangeRejectOk, '
      'invalidEnvelopeStartPtsRejectOk: $invalidEnvelopeStartPtsRejectOk, '
      'invalidEnvelopeGainRejectOk: $invalidEnvelopeGainRejectOk, '
      'noPerMixAllocationOk: $noPerMixAllocationOk, '
      'schedulerUnchangedOk: $schedulerUnchangedOk, '
      'productionMixdownUntouchedOk: $productionMixdownUntouchedOk, '
      'lifecycleOk: $lifecycleOk, '
      'stackScoped: $stackScoped, '
      'canonical: $canonical, '
      'normalizedKeyframeCount: $normalizedKeyframeCount, '
      'staticFadeKeyframeCount: $staticFadeKeyframeCount, '
      'evaluationSampleCount: $evaluationSampleCount, '
      'maxGainDiffScaled: $maxGainDiffScaled, '
      'envelopeEvaluations: $envelopeEvaluations, '
      'framesMixed: $framesMixed, '
      'sampleRate: $sampleRate, '
      'channelCount: $channelCount, '
      'maxFramesPerMix: $maxFramesPerMix, '
      'minEffectiveGain: $minEffectiveGain, '
      'maxEffectiveGain: $maxEffectiveGain, '
      'staticGainChecksumHex: $staticGainChecksumHex, '
      'envelopeMixChecksumHex: $envelopeMixChecksumHex, '
      'nullEnvelopeChecksumHex: $nullEnvelopeChecksumHex, '
      'baselineStaticChecksumHex: $baselineStaticChecksumHex, '
      'lastError: $lastError)';
}
