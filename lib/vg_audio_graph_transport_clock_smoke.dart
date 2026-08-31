// vg_audio_graph_transport_clock_smoke.dart
// vanguard_media_engine — P4-AUDIO-GRAPH-TRANSPORT-CLOCK: Android True-DAG Phase 4
// synchronous graph-edge-routed audio window scheduler proof smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AudioGraphTransportClockSmoke` MethodChannel route.
// Diagnostic-only — validates native vanguard::audio::GraphAudioScheduler
// graph-edge-routed audio window rendering, exact frame-window math, PTS derivation,
// microsecond drift prevention, timeline gating, mixed PCM checksum verification,
// silence windows, stale generation rejection, sample rate mismatch rejection,
// capacity guards, and zero per-window allocations.
//
// Honest non-claims:
// - Pure in-memory C++ graph edge routing, exact frame window math, PTS derivation,
//   microsecond drift prevention, timeline gating, mixed PCM checksum verification,
//   silence windows, stale generation rejection, sample rate mismatch rejection,
//   and capacity guard micro-proof only.
// - Does not claim audible or realtime audio playback.
// - Does not use AudioTrack, AAudio, OpenSL, or Oboe.
// - Does not use threads, locks, ring buffers, queues, or backpressure.
// - Does not perform file IO.
// - Does not use MediaCodec or MediaExtractor.
// - Does not add C++ -> Kotlin callbacks.
// - Does not reroute export.
// - Does not touch app/editor/product UI.
// - Does not stream.
// - Does not touch iOS.
// - Does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK or P4-AUDIO-MIXBUS.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAudioGraphTransportClockSmokeReport.runAndroidDagPhase4AudioGraphTransportClockSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAudioGraphTransportClockSmokeReport {
  const VGAudioGraphTransportClockSmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.raw,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidDagPhase4AudioGraphTransportClockSmoke';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_graph_edge_routed_audio_window_scheduler_proof_only_no_realtime_no_audio_track_no_playback_no_queue_no_backpressure_no_threads_no_export_reroute_no_product';

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

  /// Whether scheduler routed only providers registered for connected edges.
  bool get schedulerGraphEdgeRoutingOk =>
      _boolMetric('schedulerGraphEdgeRoutingOk');

  /// Whether frame window math exactly rendered total frames across windows including partial final window.
  bool get frameWindowMathExactOk => _boolMetric('frameWindowMathExactOk');

  /// Whether PTS derivation with non-divisible sample rate matches exact monotonic integer math.
  bool get ptsDerivationOk => _boolMetric('ptsDerivationOk');

  /// Whether frame cursor accumulation over >=1000 windows has zero microsecond drift.
  bool get noMicrosecondDriftOk => _boolMetric('noMicrosecondDriftOk');

  /// Whether timeline gating returns silence before start, PCM at active window, and silence at exclusive end boundary.
  bool get timelineGatingWindowOk => _boolMetric('timelineGatingWindowOk');

  /// Whether scheduler-routed PCM mix matches independent direct-mix checksum reference.
  bool get mixRoutingChecksumOk => _boolMetric('mixRoutingChecksumOk');

  /// Whether zero routed providers produce silence output without invoking mix().
  bool get silenceWindowOk => _boolMetric('silenceWindowOk');

  /// Whether graph mutation after scheduler construction fails closed with kStaleGeneration.
  bool get staleGenerationRejectOk => _boolMetric('staleGenerationRejectOk');

  /// Whether provider format sample rate mismatch fails closed with kSampleRateMismatch without resampling.
  bool get sampleRateMismatchRejectOk =>
      _boolMetric('sampleRateMismatchRejectOk');

  /// Whether frame count exceeding maxFramesPerMix is rejected with output buffer unmodified.
  bool get capacityGuardOk => _boolMetric('capacityGuardOk');

  /// Whether internal scratch capacity is invariant across renderWindow calls (zero per-window allocations).
  bool get noPerWindowAllocationOk => _boolMetric('noPerWindowAllocationOk');

  /// Whether repeated renderWindow calls produce bitwise identical outputs and deterministic port order.
  bool get deterministicPortOrderOk => _boolMetric('deterministicPortOrderOk');

  /// Whether scheduler and node lifecycle tear-down succeeded cleanly.
  bool get lifecycleOk => _boolMetric('lifecycleOk');

  /// Whether execution was stack-scoped and clean.
  bool get stackScoped => _boolMetric('stackScoped');

  // ── Numeric Getters ───────────────────────────────────────────────────────

  int _intMetric(String key, [int defaultValue = 0]) {
    final val = metrics[key] ?? raw[key];
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val) ?? defaultValue;
    return defaultValue;
  }

  /// Total rendered audio frames across all scheduler windows.
  int get renderedFrames => _intMetric('renderedFrames');

  /// Checksum of rendered audio samples in the first window.
  int get mixChecksum => _intMetric('mixChecksum');

  /// Expected checksum of direct-mix audio samples.
  int get expectedChecksum => _intMetric('expectedChecksum');

  /// Number of mix calls executed during the window loop.
  int get schedulerMixCallCount => _intMetric('schedulerMixCallCount');

  /// Number of mix calls executed during silence test (must be 0).
  int get silenceMixCallCount => _intMetric('silenceMixCallCount');

  /// Total number of rendered scheduler windows.
  int get windowCount => _intMetric('windowCount');

  /// Number of frames rendered in the partial final window.
  int get partialFinalWindowFrames => _intMetric('partialFinalWindowFrames');

  /// Microsecond drift frame difference computed against naive float accumulation.
  int get microsecondAccumulationDriftFrames =>
      _intMetric('microsecondAccumulationDriftFrames');

  /// Whether all native diagnostic lanes passed.
  bool get allNativeLanesPass =>
      schedulerGraphEdgeRoutingOk &&
      frameWindowMathExactOk &&
      ptsDerivationOk &&
      noMicrosecondDriftOk &&
      timelineGatingWindowOk &&
      mixRoutingChecksumOk &&
      silenceWindowOk &&
      staleGenerationRejectOk &&
      sampleRateMismatchRejectOk &&
      capacityGuardOk &&
      noPerWindowAllocationOk &&
      deterministicPortOrderOk &&
      lifecycleOk &&
      stackScoped;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAudioGraphTransportClockSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAudioGraphTransportClockSmokeReport(
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

    return VGAudioGraphTransportClockSmokeReport(
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

  /// Invokes the Android True-DAG Phase 4 synchronous graph-edge-routed audio
  /// window scheduler proof smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a fallback report if timed out
  /// or if a [PlatformException] / error occurs.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAudioGraphTransportClockSmokeReport>
  runAndroidDagPhase4AudioGraphTransportClockSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAudioGraphTransportClockSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGAudioGraphTransportClockSmokeReport(
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
      return VGAudioGraphTransportClockSmokeReport(
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
      return VGAudioGraphTransportClockSmokeReport(
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
    return other is VGAudioGraphTransportClockSmokeReport &&
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
      'VGAudioGraphTransportClockSmokeReport('
      'pass: $pass, '
      'proofBoundary: $proofBoundary, '
      'raw: $raw, '
      'metrics: $metrics, '
      'lastError: $lastError)';
}
