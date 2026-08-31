// vg_audio_clock_smoke.dart
// vanguard_media_engine — P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice C: Android True-DAG Phase 4
// platform-neutral native AudioClock diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AudioClockSmoke` MethodChannel route.
// Diagnostic-only — validates native vanguard::audio::AudioClock
// caller-clocked, lock-free monotonic media-position tracker and drift telemetry.
//
// Honest non-claims:
// - Does not claim realtime or audible playback.
// - Does not use AudioTrack, AAudio, OpenSL, or Oboe.
// - Does not implement a production PCM decoder or writer.
// - Does not reroute export.
// - Does not stream.
// - Does not touch iOS or product/editor UI.
// - Does not read any internal wall clock; every AudioClock call is fed an explicit, caller-chosen sysTimeNs.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAudioClockSmokeReport.runAndroidDagPhase4AudioClockSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAudioClockSmokeReport {
  const VGAudioClockSmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.raw,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runAndroidDagPhase4AudioClockSmoke';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_audio_clock_monotonic_timebase_and_drift_proof_only_no_audio_track_no_aaudio_no_audible_playback_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product_no_internal_wall_clock_read';

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// Map of raw string outputs emitted by native smoke execution.
  final Map<String, String> raw;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  // ── Boolean Lane Helpers & Getters ────────────────────────────────────────

  bool _boolMetric(String key) {
    final val = metrics[key] ?? raw[key];
    if (val is bool) return val;
    if (val is String) {
      final lower = val.trim().toLowerCase();
      return lower == 'true' || lower == 'pass' || lower == 'success';
    }
    return false;
  }

  /// Whether atomic sequence counter and lock-free seqlock read/write operations succeed without contention or torn states.
  bool get audioClockLockFreeOk => _boolMetric('audioClockLockFreeOk');

  /// Whether monotonic time-to-position progression arithmetic accurately converts elapsed nanoseconds at 1.0x speed.
  bool get clockMathOk => _boolMetric('clockMathOk');

  /// Whether rational timebase scaling maintains integer exactness without float accumulation drift.
  bool get rationalExactnessOk => _boolMetric('rationalExactnessOk');

  /// Whether double-precision floating point calculations do not diverge from integer timebase arithmetic.
  bool get doubleDivergenceOk => _boolMetric('doubleDivergenceOk');

  /// Whether play/pause/resume state transitions hold position frozen while paused and resume monotonically.
  bool get playPauseResumeOk => _boolMetric('playPauseResumeOk');

  /// Whether explicit seek updates media position accurately and resets monotonic baseline without glitching.
  bool get seekOk => _boolMetric('seekOk');

  /// Whether variable playback speeds calculate media position advances with exact rate scaling.
  bool get speedMathOk => _boolMetric('speedMathOk');

  /// Whether randomized step fuzzing guarantees non-decreasing monotonic position reporting under forward time.
  bool get monotonicityFuzzOk => _boolMetric('monotonicityFuzzOk');

  /// Whether extreme elapsed time or large timestamps saturate cleanly without undefined integer overflow.
  bool get overflowSaturationOk => _boolMetric('overflowSaturationOk');

  /// Whether negative, zero, NaN, infinite, or out-of-range speed values are safely rejected and clamped.
  bool get invalidSpeedRejectOk => _boolMetric('invalidSpeedRejectOk');

  /// Whether drift telemetry tracking observes timebase skew inertly without corrupting clock position.
  bool get driftTelemetryInertOk => _boolMetric('driftTelemetryInertOk');

  /// Whether seek hand-off coordination with SPSC audio ring buffer and sample provider synchronizes cleanly.
  bool get ringSeekCoordinationOk => _boolMetric('ringSeekCoordinationOk');

  /// Whether AudioClock construct, configure, reset, and teardown lifecycle contracts succeed cleanly.
  bool get lifecycleOk => _boolMetric('lifecycleOk');

  /// Whether diagnostic execution was stack-scoped and clean without persistent native handles.
  bool get stackScoped => _boolMetric('stackScoped');

  // ── Numeric Getters ───────────────────────────────────────────────────────

  int _intMetric(String key, [int defaultValue = 0]) {
    final val = metrics[key] ?? raw[key];
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val) ?? defaultValue;
    return defaultValue;
  }

  /// Final media position in microseconds at the end of smoke execution.
  int get finalPositionUs => _intMetric('finalPositionUs');

  /// Media position in microseconds observed during pause state.
  int get pausedPositionUs => _intMetric('pausedPositionUs');

  /// Media position in microseconds observed after resume.
  int get resumedPositionUs => _intMetric('resumedPositionUs');

  /// Media position in microseconds observed after seek.
  int get seekPositionUs => _intMetric('seekPositionUs');

  /// Microsecond drift delta measured by drift telemetry.
  int get driftDeltaUs => _intMetric('driftDeltaUs');

  /// Number of drift telemetry samples recorded.
  int get driftSampleCount => _intMetric('driftSampleCount');

  /// Number of iterations executed during monotonicity fuzz testing.
  int get fuzzIterations => _intMetric('fuzzIterations');

  /// Whether all native diagnostic lanes passed.
  bool get allNativeLanesPass =>
      audioClockLockFreeOk &&
      clockMathOk &&
      rationalExactnessOk &&
      doubleDivergenceOk &&
      playPauseResumeOk &&
      seekOk &&
      speedMathOk &&
      monotonicityFuzzOk &&
      overflowSaturationOk &&
      invalidSpeedRejectOk &&
      driftTelemetryInertOk &&
      ringSeekCoordinationOk &&
      lifecycleOk &&
      stackScoped;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAudioClockSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAudioClockSmokeReport(
        pass: false,
        proofBoundary: '',
        raw: <String, String>{'reason': 'native_result_not_a_map'},
        metrics: <String, Object?>{
          'status': 'FAIL',
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

    return VGAudioClockSmokeReport(
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

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android True-DAG Phase 4 native AudioClock
  /// diagnostic proof smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a fallback report if timed out
  /// or if a [PlatformException] / error occurs.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAudioClockSmokeReport> runAndroidDagPhase4AudioClockSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAudioClockSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGAudioClockSmokeReport(
        pass: false,
        proofBoundary: proofBoundaryConstant,
        raw: const <String, String>{'status': 'FAIL', 'reason': 'timeout'},
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'timeout',
          'error': te.toString(),
        },
        lastError: 'timeout: $te',
      );
    } on PlatformException catch (pe) {
      return VGAudioClockSmokeReport(
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
        },
        lastError: 'platform_exception:${pe.code}:${pe.message}',
      );
    } catch (e) {
      return VGAudioClockSmokeReport(
        pass: false,
        proofBoundary: proofBoundaryConstant,
        raw: <String, String>{'status': 'FAIL', 'reason': 'exception:$e'},
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'exception',
          'error': e.toString(),
        },
        lastError: 'exception:$e',
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGAudioClockSmokeReport &&
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
      'VGAudioClockSmokeReport('
      'pass: $pass, '
      'proofBoundary: $proofBoundary, '
      'raw: $raw, '
      'metrics: $metrics, '
      'lastError: $lastError)';
}
