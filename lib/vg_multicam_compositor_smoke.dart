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

import 'vg_live_preview_config.dart';

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

/// Typed report returned by
/// [VGMultiCamDescriptorBridgeSmokeReport.runAndroidDagPhase3MultiCamDescriptorBridgeSmoke],
/// mirroring the native P3-MULTICAM-NODE-DART-TO-NATIVE-LAYOUT-MAP-BRIDGE
/// diagnostic result map.
///
/// Diagnostic only: proves that a Dart layout map (the
/// `layoutMode`/`pipLayout`/`splitLayout` shape shared by
/// [VGLivePreviewConfig.toMap] and `VGDualCameraDescriptor.toMap`) can be
/// consumed by the Android bridge and converted into the native
/// `MultiCamCompositorNode::computeLayout` layout math. Does not claim
/// camera open, concurrent capture, render, OES, recording/export,
/// product/editor UI, or iOS.
@immutable
class VGMultiCamDescriptorBridgeSmokeReport {
  const VGMultiCamDescriptorBridgeSmokeReport({
    required this.pass,
    required this.decision,
    required this.raw,
    required this.proofBoundary,
    required this.metrics,
  });

  /// Canonical proof boundary string emitted by the native bridge harness.
  static const String proofBoundaryConstant =
      'dart_layout_map_to_native_multicam_layout_diagnostic_only_no_camera_no_render_no_recording_no_product';

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed lifecycle decision.
  final VGMultiCamCompositorSmokeDecision decision;

  /// Raw return string from native C++ bridge function.
  final String raw;

  /// Proof boundary string proving execution of the verified bridge harness.
  final String proofBoundary;

  /// Key/value metrics map emitted by native bridge execution.
  final Map<String, String> metrics;

  /// The layout mode the native bridge resolved the request to
  /// (`'pip'` or `'splitScreen'`), after applying the unknown-value fallback.
  String? get layoutModeResolved => metrics['layoutModeResolved'];

  /// The PiP anchor the native bridge resolved the request to, after
  /// applying the unknown-value fallback (unknown -> `'bottomRight'`).
  String? get anchorResolved => metrics['anchorResolved'];

  /// The split direction the native bridge resolved the request to, after
  /// applying the unknown-value fallback (unknown -> `'topBottom'`).
  String? get directionResolved => metrics['directionResolved'];

  /// Whether every native output rect/opacity/corner-radius field is finite
  /// and within the normalized [0,1] unit range.
  bool get rectsFiniteInUnitPass => metrics['rectsFiniteInUnitOk'] == 'true';

  /// Whether this request exercised the freeFloating PiP center-geometry
  /// proof lane (mode resolved to PiP and anchor resolved to freeFloating).
  bool get pipCenterApplicable => metrics['pipCenterApplicable'] == 'true';

  /// Whether the native secondary-viewport center reproduced the requested
  /// `centerX`/`centerY` when [pipCenterApplicable] is true.
  bool get pipCenterPass => metrics['pipCenterOk'] == 'true';

  /// Whether this request exercised the leftRight split-consumption proof
  /// lane (mode resolved to splitScreen and direction resolved to leftRight).
  bool get splitConsumptionApplicable =>
      metrics['splitConsumptionApplicable'] == 'true';

  /// Whether the native primary/secondary viewport widths reproduced the
  /// requested `splitRatio` with no gap/overlap when
  /// [splitConsumptionApplicable] is true.
  bool get splitConsumptionPass => metrics['splitConsumptionOk'] == 'true';

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether all native diagnostic lanes applicable to this request passed.
  bool get allNativeLanesPass =>
      rectsFiniteInUnitPass &&
      (!pipCenterApplicable || pipCenterPass) &&
      (!splitConsumptionApplicable || splitConsumptionPass);

  /// Convenience getter for whether [decision] is [VGMultiCamCompositorSmokeDecision.pass].
  bool get isPass => decision == VGMultiCamCompositorSmokeDecision.pass;

  /// Convenience getter for whether [decision] is [VGMultiCamCompositorSmokeDecision.fail].
  bool get isFail => decision == VGMultiCamCompositorSmokeDecision.fail;

  /// Convenience getter for whether [decision] is [VGMultiCamCompositorSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGMultiCamCompositorSmokeDecision.harnessException;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGMultiCamDescriptorBridgeSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGMultiCamDescriptorBridgeSmokeReport(
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

    return VGMultiCamDescriptorBridgeSmokeReport(
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

  static const String _method =
      'runAndroidDagPhase3MultiCamDescriptorBridgeSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android True-DAG P3-MULTICAM-NODE-DART-TO-NATIVE-LAYOUT-
  /// MAP-BRIDGE diagnostic: sends [config]'s `toMap()` layout map to the
  /// native bridge and reports whether the native `MultiCamLayout` math
  /// reproduced the requested layout.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a fallback
  /// [VGMultiCamCompositorSmokeDecision.harnessException] report if timed out
  /// or if a [PlatformException] / error occurs.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGMultiCamDescriptorBridgeSmokeReport>
  runAndroidDagPhase3MultiCamDescriptorBridgeSmoke({
    required VGLivePreviewConfig config,
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method, config.toMap());
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGMultiCamDescriptorBridgeSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGMultiCamDescriptorBridgeSmokeReport(
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
      return VGMultiCamDescriptorBridgeSmokeReport(
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
      return VGMultiCamDescriptorBridgeSmokeReport(
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
    return other is VGMultiCamDescriptorBridgeSmokeReport &&
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
      'VGMultiCamDescriptorBridgeSmokeReport('
      'pass: $pass, '
      'decision: $decision, '
      'raw: $raw, '
      'proofBoundary: $proofBoundary, '
      'metrics: $metrics)';
}
