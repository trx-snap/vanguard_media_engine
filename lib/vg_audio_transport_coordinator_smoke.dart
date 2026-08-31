// vg_audio_transport_coordinator_smoke.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice D: Android True-DAG Phase 4
// native ClockedAudioTransportCoordinator diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AudioTransportCoordinatorSmoke` MethodChannel route.
// Diagnostic-only - validates native vanguard::audio::ClockedAudioTransportCoordinator
// caller-clocked, clock-driven audio transport coordination, start/seek ACK gating,
// bounded catch-up, backpressure clock protection, pause/resume gating, silence pushes,
// scheduler error isolation, non-unity speed rejection, frame overflow protection,
// and zero steady-state allocation native proof.
//
// Honest non-claims:
// - Pure in-memory C++ proof only; no AudioTrack/AAudio/OpenSL/Oboe, no OS callbacks,
//   no production decoder writer, no export reroute, no streaming, no iOS,
//   no product/editor UI, no internal wall-clock read, no threads, no locks,
//   no float timebase, no resample, no speed change, no source provider ring seek,
//   output ring only, unity speed only.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAudioTransportCoordinatorSmokeReport.runAndroidDagPhase4AudioTransportCoordinatorSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAudioTransportCoordinatorSmokeReport {
  const VGAudioTransportCoordinatorSmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.raw,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidDagPhase4AudioTransportCoordinatorSmoke';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_clock_driven_audio_transport_coordinator_proof_only_no_audio_track_no_os_callback_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product_no_internal_wall_clock_read_no_threads_no_locks_no_float_timebase_no_resample_no_speed_change_no_source_provider_ring_seek_output_ring_only_unity_speed_only';

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

  // ---- Boolean Lane Helpers & Getters -------------------------------------

  bool _boolMetric(String key) {
    final val = metrics[key] ?? raw[key];
    if (val is bool) return val;
    if (val is String) {
      final lower = val.trim().toLowerCase();
      return lower == 'true' || lower == 'pass' || lower == 'success';
    }
    return false;
  }

  /// Whether coordinator constructor validates all required dependencies and rejects null or invalid configurations.
  bool get coordinatorConstructorValidationOk =>
      _boolMetric('coordinatorConstructorValidationOk');

  /// Whether start command awaits ACK gate before allowing clock-driven audio dispatch.
  bool get startAwaitAckGateOk => _boolMetric('startAwaitAckGateOk');

  /// Whether clock-driven dispatch advances media time and renders audio frames monotonically.
  bool get clockDrivenDispatchOk => _boolMetric('clockDrivenDispatchOk');

  /// Whether bounded catch-up dispatches bounded frame batches without unbounded looping or frame drops.
  bool get boundedCatchUpOk => _boolMetric('boundedCatchUpOk');

  /// Whether backpressure in the output ring buffer prevents clock mutation and avoids buffer overrun.
  bool get backpressureNoClockMutationOk =>
      _boolMetric('backpressureNoClockMutationOk');

  /// Whether pause and resume state transitions freeze dispatch during pause and resume cleanly without frame leaks.
  bool get pauseResumeNoDispatchOk => _boolMetric('pauseResumeNoDispatchOk');

  /// Whether seek command halts dispatch until seek ACK gate is fulfilled.
  bool get seekAwaitAckGateOk => _boolMetric('seekAwaitAckGateOk');

  /// Whether silence window is pushed correctly during timeline gaps or un-rendered intervals.
  bool get silenceWindowPushedOk => _boolMetric('silenceWindowPushedOk');

  /// Whether scheduler errors isolate safely without advancing the audio transport cursor.
  bool get schedulerErrorNoCursorAdvanceOk =>
      _boolMetric('schedulerErrorNoCursorAdvanceOk');

  /// Whether non-unity playback speeds are rejected safely in this proof boundary.
  bool get nonUnitySpeedRejectOk => _boolMetric('nonUnitySpeedRejectOk');

  /// Whether extreme time conversions and position offsets are protected against integer overflow.
  bool get frameConversionOverflowOk =>
      _boolMetric('frameConversionOverflowOk');

  /// Whether steady-state execution incurs zero heap allocations.
  bool get noSteadyStateAllocationOk =>
      _boolMetric('noSteadyStateAllocationOk');

  /// Whether coordinator lifecycle and resource teardown succeed cleanly.
  bool get lifecycleOk => _boolMetric('lifecycleOk');

  /// Whether execution was stack-scoped and clean without persistent handles.
  bool get stackScoped => _boolMetric('stackScoped');

  // ---- Numeric Getters ----------------------------------------------------

  int _intMetric(String key, [int defaultValue = 0]) {
    final val = metrics[key] ?? raw[key];
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val) ?? defaultValue;
    return defaultValue;
  }

  /// Total rendered frames across clock-driven dispatch cycles.
  int get clockDrivenFramesRendered => _intMetric('clockDrivenFramesRendered');

  /// Total number of bounded catch-up dispatch invocations.
  int get boundedCatchUpCalls => _intMetric('boundedCatchUpCalls');

  /// Total audio frames rendered during bounded catch-up invocations.
  int get boundedCatchUpTotalFrames => _intMetric('boundedCatchUpTotalFrames');

  /// Total silence frames pushed to the output ring.
  int get silenceFramesPushed => _intMetric('silenceFramesPushed');

  /// Total frame conversions that required overflow saturation protection.
  int get frameOfPositionSaturated => _intMetric('frameOfPositionSaturated');

  /// Whether all native diagnostic lanes passed.
  bool get allNativeLanesPass =>
      coordinatorConstructorValidationOk &&
      startAwaitAckGateOk &&
      clockDrivenDispatchOk &&
      boundedCatchUpOk &&
      backpressureNoClockMutationOk &&
      pauseResumeNoDispatchOk &&
      seekAwaitAckGateOk &&
      silenceWindowPushedOk &&
      schedulerErrorNoCursorAdvanceOk &&
      nonUnitySpeedRejectOk &&
      frameConversionOverflowOk &&
      noSteadyStateAllocationOk &&
      lifecycleOk &&
      stackScoped;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAudioTransportCoordinatorSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAudioTransportCoordinatorSmokeReport(
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

    return VGAudioTransportCoordinatorSmokeReport(
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

  /// Invokes the Android True-DAG Phase 4 native ClockedAudioTransportCoordinator
  /// diagnostic proof smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a fallback report if timed out
  /// or if a [PlatformException] / error occurs.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAudioTransportCoordinatorSmokeReport>
  runAndroidDagPhase4AudioTransportCoordinatorSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAudioTransportCoordinatorSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGAudioTransportCoordinatorSmokeReport(
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
      return VGAudioTransportCoordinatorSmokeReport(
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
      return VGAudioTransportCoordinatorSmokeReport(
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
    return other is VGAudioTransportCoordinatorSmokeReport &&
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
      'VGAudioTransportCoordinatorSmokeReport('
      'pass: $pass, '
      'proofBoundary: $proofBoundary, '
      'raw: $raw, '
      'metrics: $metrics, '
      'lastError: $lastError)';
}
