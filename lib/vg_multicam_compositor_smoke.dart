// vg_multicam_compositor_smoke.dart
// vanguard_media_engine — P3-MULTICAM-NODE: Android True-DAG V4.3 foundation
// MultiCamCompositorNode native topology + PiP/split layout-math smoke diagnostic.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase3MultiCamCompositorSmoke` MethodChannel route.
// Diagnostic-only — validates native MultiCamCompositorNode graph port topology,
// PiP free-floating math, 4-corner anchors & Y-down margin geometry, split-screen
// tiling, and fail-safe clamping for nonfinite inputs.
// No render, no Camera2, no recording, no export, and no product/editor UI.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 3 MultiCamCompositorNode smoke harness.
enum VGMultiCamCompositorSmokeDecision {
  /// All native MultiCamCompositorNode topology and layout math assertions passed.
  pass,

  /// One or more native MultiCamCompositorNode assertions failed.
  fail,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw native/Kotlin decision string to the matching enum value,
  /// falling back to [harnessException] for unrecognised/missing values.
  static VGMultiCamCompositorSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGMultiCamCompositorSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') return VGMultiCamCompositorSmokeDecision.pass;
    if (normalized == 'fail') return VGMultiCamCompositorSmokeDecision.fail;
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGMultiCamCompositorSmokeDecision.harnessException;
    }
    for (final value in VGMultiCamCompositorSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGMultiCamCompositorSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGMultiCamCompositorSmokeReport.runAndroidDagPhase3MultiCamCompositorSmoke],
/// mirroring the native harness's result map.
@immutable
class VGMultiCamCompositorSmokeReport {
  const VGMultiCamCompositorSmokeReport({
    required this.pass,
    required this.decision,
    required this.raw,
    required this.proofBoundary,
    required this.metrics,
  });

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording';

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed lifecycle decision.
  final VGMultiCamCompositorSmokeDecision decision;

  /// Raw return string from native C++ smoke function.
  final String raw;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, String> metrics;

  /// Whether the native node kind, type, and input/output ports match expectations.
  bool get nodeTopologyPass => metrics['nodeOk'] == 'true';

  /// Whether the PiP free-floating geometry and viewport calculations passed.
  bool get pipFreeFloatingPass => metrics['pipFreeFloatOk'] == 'true';

  /// Whether all 4 corner anchors and Y-down margin geometry calculations passed.
  bool get anchorsPass => metrics['anchorsOk'] == 'true';

  /// Whether split-screen top/bottom and left/right tiling calculations passed.
  bool get splitPass => metrics['splitOk'] == 'true';

  /// Whether fail-safe clamping for nonfinite/invalid inputs passed.
  bool get clampPass => metrics['clampOk'] == 'true';

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether all native diagnostic lanes passed.
  bool get allNativeLanesPass =>
      nodeTopologyPass &&
      pipFreeFloatingPass &&
      anchorsPass &&
      splitPass &&
      clampPass;

  /// Convenience getter for whether [decision] is [VGMultiCamCompositorSmokeDecision.pass].
  bool get isPass => decision == VGMultiCamCompositorSmokeDecision.pass;

  /// Convenience getter for whether [decision] is [VGMultiCamCompositorSmokeDecision.fail].
  bool get isFail => decision == VGMultiCamCompositorSmokeDecision.fail;

  /// Convenience getter for whether [decision] is [VGMultiCamCompositorSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGMultiCamCompositorSmokeDecision.harnessException;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGMultiCamCompositorSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGMultiCamCompositorSmokeReport(
        pass: false,
        decision: VGMultiCamCompositorSmokeDecision.harnessException,
        raw: raw?.toString() ?? '',
        proofBoundary: '',
        metrics: const <String, String>{'reason': 'native_result_not_a_map'},
      );
    }

    final rawString = (raw['raw'] as String?) ?? '';
    final proofBoundary = (raw['proofBoundary'] as String?) ?? '';

    final metricsRaw = raw['metrics'];
    final metrics = <String, String>{};
    if (metricsRaw is Map) {
      for (final entry in metricsRaw.entries) {
        final k = entry.key?.toString();
        final v = entry.value?.toString();
        if (k != null && v != null) {
          metrics[k] = v;
        }
      }
    }

    // If metrics map was omitted or empty, fall back to parsing from raw string.
    if (metrics.isEmpty && rawString.isNotEmpty) {
      for (final part in rawString.split(';')) {
        final eq = part.indexOf('=');
        if (eq > 0) {
          final k = part.substring(0, eq).trim();
          final v = part.substring(eq + 1).trim();
          if (k.isNotEmpty) {
            metrics[k] = v;
          }
        }
      }
    }

    final pass = raw['pass'] as bool? ?? false;
    final decision = VGMultiCamCompositorSmokeDecision.fromRaw(raw['decision']);

    return VGMultiCamCompositorSmokeReport(
      pass: pass,
      decision: decision,
      raw: rawString,
      proofBoundary: proofBoundary,
      metrics: Map<String, String>.unmodifiable(metrics),
    );
  }

  /// Serializes the report back to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'decision': decision.name,
      'raw': raw,
      'proofBoundary': proofBoundary,
      'metrics': Map<String, String>.from(metrics),
    };
  }

  static const String _method = 'runAndroidDagPhase3MultiCamCompositorSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android True-DAG Phase 3 MultiCamCompositorNode native
  /// topology and PiP/split layout-math diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a fallback
  /// [VGMultiCamCompositorSmokeDecision.harnessException] report if timed out or
  /// if a [PlatformException] / error occurs.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGMultiCamCompositorSmokeReport>
  runAndroidDagPhase3MultiCamCompositorSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGMultiCamCompositorSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGMultiCamCompositorSmokeReport(
        pass: false,
        decision: VGMultiCamCompositorSmokeDecision.harnessException,
        raw: 'status=FAIL;reason=timeout',
        proofBoundary: proofBoundaryConstant,
        metrics: <String, String>{
          'status': 'FAIL',
          'reason': 'timeout',
          'error': te.toString(),
        },
      );
    } on PlatformException catch (pe) {
      return VGMultiCamCompositorSmokeReport(
        pass: false,
        decision: VGMultiCamCompositorSmokeDecision.harnessException,
        raw: 'status=FAIL;reason=platform_exception:${pe.code}',
        proofBoundary: proofBoundaryConstant,
        metrics: <String, String>{
          'status': 'FAIL',
          'reason': 'platform_exception',
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGMultiCamCompositorSmokeReport(
        pass: false,
        decision: VGMultiCamCompositorSmokeDecision.harnessException,
        raw: 'status=FAIL;reason=exception:$e',
        proofBoundary: proofBoundaryConstant,
        metrics: <String, String>{
          'status': 'FAIL',
          'reason': 'exception',
          'error': e.toString(),
        },
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGMultiCamCompositorSmokeReport &&
        other.pass == pass &&
        other.decision == decision &&
        other.raw == raw &&
        other.proofBoundary == proofBoundary &&
        mapEquals(other.metrics, metrics);
  }

  @override
  int get hashCode =>
      Object.hash(pass, decision, raw, proofBoundary, _stableMapHash(metrics));

  static int _stableMapHash(Map<String, String> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGMultiCamCompositorSmokeReport('
      'pass: $pass, '
      'decision: $decision, '
      'raw: $raw, '
      'proofBoundary: $proofBoundary, '
      'metrics: $metrics)';
}
