// vg_audio_mix_bus_smoke.dart
// vanguard_media_engine — P4-AUDIO-MIXBUS: Android True-DAG Phase 4
// AudioMixBusNode PCM16 mix-math diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AudioMixBusSmoke` MethodChannel route.
// Diagnostic-only — validates native vanguard::audio::AudioMixBusNode
// PCM16 mix math, upmix/downmix, saturation/clipping, truncation,
// silence handling, and error rejection cases without decoder/AAC/export/playback.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by [VGAudioMixBusSmokeReport.runAndroidDagPhase4AudioMixBusSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGAudioMixBusSmokeReport {
  const VGAudioMixBusSmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.raw,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_audio_mix_bus_node_pcm16_mix_math_only_no_decoder_no_aac_no_export_no_realtime_no_playback_no_product';

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// Map of lane raw string outputs emitted by native smoke execution.
  final Map<String, String> raw;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  // ── Lane Getters ─────────────────────────────────────────────────────────

  bool _boolMetric(String key) {
    final val = metrics[key];
    if (val is bool) return val;
    if (val is String) {
      final lower = val.trim().toLowerCase();
      return lower == 'true' || lower == 'pass' || lower == 'success';
    }
    return false;
  }

  bool _lanePass(String laneName) {
    return _boolMetric('$laneName.pass') || _boolMetric(laneName);
  }

  /// Whether topology and port reflection checks passed.
  bool get topologyPorts => _lanePass('topologyPorts');
  bool get topologyPortsPass => topologyPorts;

  /// Whether stereo-to-stereo deterministic mix math passed.
  bool get stereoStereoDeterministic => _lanePass('stereoStereoDeterministic');
  bool get stereoStereoDeterministicPass => stereoStereoDeterministic;

  /// Whether mono-to-stereo upmix math passed.
  bool get monoToStereoUpmix => _lanePass('monoToStereoUpmix');
  bool get monoToStereoUpmixPass => monoToStereoUpmix;

  /// Whether stereo-to-mono downmix math passed.
  bool get stereoToMonoDownmix => _lanePass('stereoToMonoDownmix');
  bool get stereoToMonoDownmixPass => stereoToMonoDownmix;

  /// Whether positive int16 saturation clamping passed.
  bool get positiveSaturation => _lanePass('positiveSaturation');
  bool get positiveSaturationPass => positiveSaturation;

  /// Whether negative int16 saturation clamping passed.
  bool get negativeSaturation => _lanePass('negativeSaturation');
  bool get negativeSaturationPass => negativeSaturation;

  /// Whether odd sample fractional scaling truncation passed.
  bool get oddSampleTruncation => _lanePass('oddSampleTruncation');
  bool get oddSampleTruncationPass => oddSampleTruncation;

  /// Whether negative downmix division truncation passed.
  bool get negativeDownmixDivision => _lanePass('negativeDownmixDivision');
  bool get negativeDownmixDivisionPass => negativeDownmixDivision;

  /// Whether shorter track silence filling passed.
  bool get shorterTrackSilence => _lanePass('shorterTrackSilence');
  bool get shorterTrackSilencePass => shorterTrackSilence;

  /// Whether longer track short-window mixing passed.
  bool get longerTrackShortWindowMix => _lanePass('longerTrackShortWindowMix');
  bool get longerTrackShortWindowMixPass => longerTrackShortWindowMix;

  /// Whether out-of-range gain rejection passed.
  bool get invalidGainRejection => _lanePass('invalidGainRejection');
  bool get invalidGainRejectionPass => invalidGainRejection;

  /// Whether NaN/Inf non-finite gain rejection passed.
  bool get nonFiniteGainRejection => _lanePass('nonFiniteGainRejection');
  bool get nonFiniteGainRejectionPass => nonFiniteGainRejection;

  /// Whether mismatched track sample rate rejection passed.
  bool get sampleRateMismatchRejection =>
      _lanePass('sampleRateMismatchRejection');
  bool get sampleRateMismatchRejectionPass => sampleRateMismatchRejection;

  /// Whether insufficient output buffer capacity rejection passed.
  bool get insufficientOutputCapacityRejection =>
      _lanePass('insufficientOutputCapacityRejection');
  bool get insufficientOutputCapacityRejectionPass =>
      insufficientOutputCapacityRejection;

  /// Whether non-existent session id rejection passed.
  bool get invalidSessionRejection => _lanePass('invalidSessionRejection');
  bool get invalidSessionRejectionPass => invalidSessionRejection;

  /// Whether session destroy and idempotent second destroy passed.
  bool get destroyIdempotent => _lanePass('destroyIdempotent');
  bool get destroyIdempotentPass => destroyIdempotent;

  /// Whether 4-track deterministic mix math passed.
  bool get fourTrackDeterministicMix => _lanePass('fourTrackDeterministicMix');
  bool get fourTrackDeterministicMixPass => fourTrackDeterministicMix;

  /// Whether no-premature-clipping intermediate mix math passed.
  bool get noPrematureClip => _lanePass('noPrematureClip');
  bool get noPrematureClipPass => noPrematureClip;

  /// Whether final int16 saturation clamping passed.
  bool get finalSaturation => _lanePass('finalSaturation');
  bool get finalSaturationPass => finalSaturation;

  /// Whether 8-track maximum capacity mix passed.
  bool get eightTrackCapacity => _lanePass('eightTrackCapacity');
  bool get eightTrackCapacityPass => eightTrackCapacity;

  /// Whether 9-track rejection admission lane passed.
  bool get nineTrackReject => _lanePass('nineTrackReject');
  bool get nineTrackRejectPass => nineTrackReject;

  /// Total number of diagnostic lanes reported.
  int get laneCount {
    final val = metrics['laneCount'];
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val) ?? 21;
    return 21;
  }

  /// Number of diagnostic lanes that passed.
  int get lanePassCount {
    final val = metrics['lanePassCount'];
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val) ?? _computeLanePassCount();
    return _computeLanePassCount();
  }

  int _computeLanePassCount() {
    var count = 0;
    if (topologyPorts) count++;
    if (stereoStereoDeterministic) count++;
    if (monoToStereoUpmix) count++;
    if (stereoToMonoDownmix) count++;
    if (positiveSaturation) count++;
    if (negativeSaturation) count++;
    if (oddSampleTruncation) count++;
    if (negativeDownmixDivision) count++;
    if (shorterTrackSilence) count++;
    if (longerTrackShortWindowMix) count++;
    if (fourTrackDeterministicMix) count++;
    if (noPrematureClip) count++;
    if (finalSaturation) count++;
    if (eightTrackCapacity) count++;
    if (invalidGainRejection) count++;
    if (nonFiniteGainRejection) count++;
    if (sampleRateMismatchRejection) count++;
    if (insufficientOutputCapacityRejection) count++;
    if (invalidSessionRejection) count++;
    if (nineTrackReject) count++;
    if (destroyIdempotent) count++;
    return count;
  }

  /// Whether all 21 native diagnostic lanes passed.
  bool get allNativeLanesPass =>
      topologyPorts &&
      stereoStereoDeterministic &&
      monoToStereoUpmix &&
      stereoToMonoDownmix &&
      positiveSaturation &&
      negativeSaturation &&
      oddSampleTruncation &&
      negativeDownmixDivision &&
      shorterTrackSilence &&
      longerTrackShortWindowMix &&
      fourTrackDeterministicMix &&
      noPrematureClip &&
      finalSaturation &&
      eightTrackCapacity &&
      invalidGainRejection &&
      nonFiniteGainRejection &&
      sampleRateMismatchRejection &&
      insufficientOutputCapacityRejection &&
      invalidSessionRejection &&
      nineTrackReject &&
      destroyIdempotent;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAudioMixBusSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAudioMixBusSmokeReport(
        pass: false,
        proofBoundary: '',
        raw: <String, String>{'reason': 'native_result_not_a_map'},
        metrics: <String, Object?>{
          'laneCount': 21,
          'lanePassCount': 0,
          'reason': 'native_result_not_a_map',
        },
        lastError: 'native_result_not_a_map',
      );
    }

    final pass = raw['pass'] as bool? ?? false;
    final proofBoundary = (raw['proofBoundary'] as String?) ?? '';
    final lastError = (raw['lastError'] as String?) ?? '';

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

    return VGAudioMixBusSmokeReport(
      pass: pass,
      proofBoundary: proofBoundary,
      raw: Map<String, String>.unmodifiable(parsedRaw),
      metrics: Map<String, Object?>.unmodifiable(parsedMetrics),
      lastError: lastError,
    );
  }

  /// Serializes the report back to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'proofBoundary': proofBoundary,
      'raw': Map<String, String>.from(raw),
      'metrics': Map<String, Object?>.from(metrics),
      'lastError': lastError,
    };
  }

  static const String _method = 'runAndroidDagPhase4AudioMixBusSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android True-DAG Phase 4 AudioMixBusNode native PCM16
  /// mix-math diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a fallback report if timed out
  /// or if a [PlatformException] / error occurs.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAudioMixBusSmokeReport> runAndroidDagPhase4AudioMixBusSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAudioMixBusSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGAudioMixBusSmokeReport(
        pass: false,
        proofBoundary: proofBoundaryConstant,
        raw: const <String, String>{'status': 'FAIL', 'reason': 'timeout'},
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'timeout',
          'error': te.toString(),
          'laneCount': 21,
          'lanePassCount': 0,
        },
        lastError: 'timeout: $te',
      );
    } on PlatformException catch (pe) {
      return VGAudioMixBusSmokeReport(
        pass: false,
        proofBoundary: proofBoundaryConstant,
        raw: <String, String>{
          'status': 'FAIL',
          'reason': 'platform_exception:${pe.code}',
        },
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'platform_exception',
          'code': pe.code,
          'message': pe.message ?? '',
          'laneCount': 21,
          'lanePassCount': 0,
        },
        lastError: 'platform_exception:${pe.code}:${pe.message}',
      );
    } catch (e) {
      return VGAudioMixBusSmokeReport(
        pass: false,
        proofBoundary: proofBoundaryConstant,
        raw: <String, String>{'status': 'FAIL', 'reason': 'exception:$e'},
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'exception',
          'error': e.toString(),
          'laneCount': 21,
          'lanePassCount': 0,
        },
        lastError: 'exception:$e',
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGAudioMixBusSmokeReport &&
        other.pass == pass &&
        other.proofBoundary == proofBoundary &&
        mapEquals(other.raw, raw) &&
        mapEquals(other.metrics, metrics) &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hash(
    pass,
    proofBoundary,
    _stableMapHash(raw),
    _stableMapHash(metrics),
    lastError,
  );

  static int _stableMapHash(Map<dynamic, dynamic> map) {
    final sortedKeys = map.keys.map((k) => k.toString()).toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGAudioMixBusSmokeReport('
      'pass: $pass, '
      'proofBoundary: $proofBoundary, '
      'raw: $raw, '
      'metrics: $metrics, '
      'lastError: $lastError)';
}
