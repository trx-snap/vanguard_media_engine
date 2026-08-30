// vg_audio_graph_topology_smoke.dart
// vanguard_media_engine — P4-AUDIO-GRAPH-TOPOLOGY: Android True-DAG Phase 4
// AudioMixBusNode DAG topology & graph-gated diagnostic mix smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AudioGraphTopologySmoke` MethodChannel route.
// Diagnostic-only — validates native vanguard::audio::AudioMixBusNode
// DAG topology participation, topological sort ordering, port-type enforcement,
// capacity limits, cycle rejection, stale generation gating, media flags,
// graph-gated mix calculation, and invalid gain rejection.
//
// Honest non-claims:
// - Proves DecodedAudioPcmSourceNode timeline gating and PTS mapping only; AudioMixBusNode remains always-active.
// - Does not claim audible or realtime audio playback.
// - Does not claim C++ graph buffer transport / PCM transport; evaluatePlayhead moves no PCM.
// - Does not claim AudioTrack integration.
// - Does not claim Pass-2 export now runs through Graph.
// - Does not close P4-AUDIO-MIXBUS or Phase 4.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAudioGraphTopologySmokeReport.runAndroidDagPhase4AudioGraphTopologySmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAudioGraphTopologySmokeReport {
  const VGAudioGraphTopologySmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.raw,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runAndroidDagPhase4AudioGraphTopologySmoke';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_audio_mix_bus_graph_topology_and_graph_gated_diagnostic_mix_only_no_realtime_no_playback_no_audio_track_no_graph_buffer_transport_no_product';

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

  /// Whether the 5-node 4-edge DAG topology build succeeded.
  bool get topologyOk => _boolMetric('topologyOk');

  /// Whether topological sort produced a stable, valid source-before-mix-before-sink order.
  bool get topoOrderOk => _boolMetric('topoOrderOk');

  /// Whether port data type compatibility enforcement succeeded (kAudioPacket vs kVideoFrame mismatch rejected).
  bool get portTypeOk => _boolMetric('portTypeOk');

  /// Whether 8-track capacity succeeded and 9th nonexistent input port connection failed closed.
  bool get capacityOk => _boolMetric('capacityOk');

  /// Whether self-loop cycle rejection succeeded without mutating edge count.
  bool get cycleRejectOk => _boolMetric('cycleRejectOk');

  /// Whether second edge targeting an occupied input port fails closed without mutating edge count.
  bool get inputFanInRejectOk => _boolMetric('inputFanInRejectOk');

  /// Whether stale generation evaluatePlayhead failed closed and executed zero mix calls.
  bool get staleGenerationOk => _boolMetric('staleGenerationOk');

  /// Whether media flags on audio-only DAG returned hasAudio=true, hasVideo=false, activeNodeCount=5.
  bool get mediaFlagsOk => _boolMetric('mediaFlagsOk');

  /// Whether graph-gated PCM mix executed and matched independent math checksum.
  bool get graphGatedMixOk => _boolMetric('graphGatedMixOk');

  /// Whether out-of-range gain rejection (gain=1.5 -> kInvalidGain) succeeded.
  bool get invalidGainOk => _boolMetric('invalidGainOk');

  /// Whether DecodedAudioPcmSourceNode timeline gating at active and inactive playheads succeeded.
  bool get audioTimelineGatingOk => _boolMetric('audioTimelineGatingOk');

  /// Whether DecodedAudioPcmSourceNode timeline PTS to local PTS mapping and defensive clamping succeeded.
  bool get audioPtsMappingOk => _boolMetric('audioPtsMappingOk');

  /// Whether graph and node lifecycle tear-down succeeded cleanly.
  bool get lifecycleOk => _boolMetric('lifecycleOk');

  /// Whether execution was stack-scoped and clean.
  bool get stackScoped => _boolMetric('stackScoped');

  /// Whether the DAG evaluation flagged active audio nodes.
  bool get hasAudio => _boolMetric('hasAudio');

  /// Whether the DAG evaluation flagged active video nodes.
  bool get hasVideo => _boolMetric('hasVideo');

  /// Whether sample saturation clipping was reported during mix.
  bool get clipped => _boolMetric('clipped');

  // ── Numeric Getters ───────────────────────────────────────────────────────

  int _intMetric(String key, [int defaultValue = 0]) {
    final val = metrics[key] ?? raw[key];
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val) ?? defaultValue;
    return defaultValue;
  }

  /// Total number of nodes in the primary topology DAG.
  int get nodeCount => _intMetric('nodeCount');

  /// Total number of edges in the primary topology DAG.
  int get edgeCount => _intMetric('edgeCount');

  /// Number of active nodes reported by evaluatePlayhead.
  int get activeNodeCount => _intMetric('activeNodeCount');

  /// Number of mix calls executed after valid graph evaluation.
  int get mixCallCount => _intMetric('mixCallCount');

  /// Number of mix calls executed under stale generation (must be 0).
  int get staleMixCallCount => _intMetric('staleMixCallCount');

  /// Number of PCM frames mixed in the gated mix test.
  int get framesMixed => _intMetric('framesMixed');

  /// Checksum of mixed PCM samples computed by AudioMixBusNode.
  int get mixChecksum => _intMetric('mixChecksum');

  /// Expected checksum of mixed PCM samples computed independently.
  int get expectedChecksum => _intMetric('expectedChecksum');

  /// Maximum absolute sample value in accumulator prior to clamping.
  int get maxAccumulatorAbs => _intMetric('maxAccumulatorAbs');

  /// Whether all native diagnostic lanes passed.
  bool get allNativeLanesPass =>
      topologyOk &&
      topoOrderOk &&
      portTypeOk &&
      capacityOk &&
      cycleRejectOk &&
      inputFanInRejectOk &&
      staleGenerationOk &&
      mediaFlagsOk &&
      graphGatedMixOk &&
      invalidGainOk &&
      audioTimelineGatingOk &&
      audioPtsMappingOk &&
      lifecycleOk &&
      stackScoped &&
      hasAudio &&
      !hasVideo;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAudioGraphTopologySmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAudioGraphTopologySmokeReport(
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

    return VGAudioGraphTopologySmokeReport(
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

  /// Invokes the Android True-DAG Phase 4 AudioMixBusNode DAG topology &
  /// graph-gated diagnostic mix smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a fallback report if timed out
  /// or if a [PlatformException] / error occurs.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAudioGraphTopologySmokeReport>
  runAndroidDagPhase4AudioGraphTopologySmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAudioGraphTopologySmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGAudioGraphTopologySmokeReport(
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
      return VGAudioGraphTopologySmokeReport(
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
      return VGAudioGraphTopologySmokeReport(
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
    return other is VGAudioGraphTopologySmokeReport &&
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
      'VGAudioGraphTopologySmokeReport('
      'pass: $pass, '
      'proofBoundary: $proofBoundary, '
      'raw: $raw, '
      'metrics: $metrics, '
      'lastError: $lastError)';
}
