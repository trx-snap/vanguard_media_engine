// vg_preview_surface_sink_node_smoke.dart
// vanguard_media_engine -- P1-DAG-MULTINODE-PREVIEW-SURFACE-SINK-NODE
// Pure Dart smoke wrapper and physical entrypoint for platform-neutral
// PreviewSurfaceSinkNode logical DAG sink node verification.
//
// Proof boundary:
//   platform_neutral_preview_surface_sink_node_logical_dag_sink_no_surface_ownership_no_android_lifecycle_no_product_app_editor_wiring
//
// Diagnostic-only: no cameras, no Surface/TextureRegistry allocation, no rendering,
// no Android lifecycle, and no product/editor/app wiring.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Canonical MethodChannel method name for the Phase 1 PreviewSurfaceSinkNode smoke route.
const String kPreviewSurfaceSinkNodeMethodName =
    'runAndroidDagPhase1PreviewSurfaceSinkNodeSmoke';

/// Canonical proof boundary required for Phase 1 PreviewSurfaceSinkNode verification.
const String kPreviewSurfaceSinkNodeProofBoundary =
    'platform_neutral_preview_surface_sink_node_logical_dag_sink_no_surface_ownership_no_android_lifecycle_no_product_app_editor_wiring';

/// Physical smoke execution start marker.
const String kPreviewSurfaceSinkNodeStartMarker =
    'ANDROID_DAG_PHASE1_PREVIEW_SURFACE_SINK_NODE_PHYSICAL_SMOKE_START';

/// Physical smoke execution pass marker.
const String kPreviewSurfaceSinkNodePassMarker =
    'ANDROID_DAG_PHASE1_PREVIEW_SURFACE_SINK_NODE_PHYSICAL_SMOKE_PASS';

/// Physical smoke execution fail marker.
const String kPreviewSurfaceSinkNodeFailMarker =
    'ANDROID_DAG_PHASE1_PREVIEW_SURFACE_SINK_NODE_PHYSICAL_SMOKE_FAIL';

/// JSON payload log prefix for physical smoke reporting.
const String kPreviewSurfaceSinkNodeJsonPrefix =
    'ANDROID_DAG_PHASE1_PREVIEW_SURFACE_SINK_NODE_JSON:';

/// Expected total lanes executed by the native smoke test.
const int kPreviewSurfaceSinkNodeExpectedTotalLanes = 10;

/// Expected passed lanes executed by the native smoke test.
const int kPreviewSurfaceSinkNodeExpectedPassedLanes = 10;

/// Immutable report model for Phase 1 PreviewSurfaceSinkNode smoke test results.
@immutable
class VGPreviewSurfaceSinkNodeSmokeReport {
  const VGPreviewSurfaceSinkNodeSmokeReport({
    required this.pass,
    required this.nativePass,
    required this.boundaryOk,
    required this.raw,
    required this.proofBoundary,
    required this.totalLanes,
    required this.passedLanes,
  });

  /// Canonical MethodChannel method name.
  static const String methodName = kPreviewSurfaceSinkNodeMethodName;

  /// Required proof boundary constant.
  static const String requiredProofBoundary =
      kPreviewSurfaceSinkNodeProofBoundary;

  /// Start marker string.
  static const String startMarker = kPreviewSurfaceSinkNodeStartMarker;

  /// Pass marker string.
  static const String passMarker = kPreviewSurfaceSinkNodePassMarker;

  /// Fail marker string.
  static const String failMarker = kPreviewSurfaceSinkNodeFailMarker;

  /// JSON output prefix string.
  static const String jsonPrefix = kPreviewSurfaceSinkNodeJsonPrefix;

  /// Expected total lanes.
  static const int expectedTotalLanes =
      kPreviewSurfaceSinkNodeExpectedTotalLanes;

  /// Expected passed lanes.
  static const int expectedPassedLanes =
      kPreviewSurfaceSinkNodeExpectedPassedLanes;

  /// Required boundary tokens that must all be present in raw/proofBoundary combined.
  static const List<String> requiredBoundaryTokens = <String>[
    'platform_neutral',
    'preview_surface_sink_node',
    'logical_dag_sink',
    'no_surface_ownership',
    'no_android_lifecycle',
    'no_product_app_editor_wiring',
  ];

  /// Overall pass flag: true only when [nativePass] is true, [boundaryOk] is true,
  /// [totalLanes] == 10, and [passedLanes] == 10.
  final bool pass;

  /// Pass flag reported by the native smoke route.
  final bool nativePass;

  /// Whether the combined raw and proofBoundary strings satisfy all required tokens.
  final bool boundaryOk;

  /// Raw return string emitted by the native smoke execution.
  final String raw;

  /// Proof boundary string emitted by the native smoke route.
  final String proofBoundary;

  /// Total number of diagnostic lanes evaluated.
  final int totalLanes;

  /// Number of diagnostic lanes that passed.
  final int passedLanes;

  /// Validates that all required boundary tokens appear within the combined
  /// [raw] and [proofBoundary] strings.
  static bool validateBoundary({String? raw, String? proofBoundary}) {
    final combined = '${raw ?? ''} ${proofBoundary ?? ''}';
    return requiredBoundaryTokens.every(combined.contains);
  }

  /// Converts this report into a serializable Map.
  Map<String, Object?> toMap() => <String, Object?>{
    'pass': pass,
    'nativePass': nativePass,
    'boundaryOk': boundaryOk,
    'raw': raw,
    'proofBoundary': proofBoundary,
    'totalLanes': totalLanes,
    'passedLanes': passedLanes,
  };

  /// Parses a report from a raw map.
  ///
  /// Returns `null` if [data] is not a Map or does not contain valid required
  /// fields. Absent `totalLanes` or `passedLanes` default to 0.
  ///
  /// The resulting [pass] is `true` only when [nativePass] is true,
  /// [boundaryOk] is true, [totalLanes] == 10, and [passedLanes] == 10.
  static VGPreviewSurfaceSinkNodeSmokeReport? fromMap(Object? data) {
    if (data is! Map) return null;

    final rawNativePass = data['nativePass'] ?? data['pass'];
    if (rawNativePass is! bool) return null;
    final nativePass = rawNativePass;

    final rawField = data['raw'];
    if (rawField is! String) return null;
    final raw = rawField;

    final proofBoundaryField = data['proofBoundary'];
    if (proofBoundaryField is! String) return null;
    final proofBoundary = proofBoundaryField;

    final totalLanesRaw = data['totalLanes'];
    final int totalLanes;
    if (totalLanesRaw == null) {
      totalLanes = 0;
    } else if (totalLanesRaw is num) {
      totalLanes = totalLanesRaw.toInt();
    } else {
      return null;
    }

    final passedLanesRaw = data['passedLanes'];
    final int passedLanes;
    if (passedLanesRaw == null) {
      passedLanes = 0;
    } else if (passedLanesRaw is num) {
      passedLanes = passedLanesRaw.toInt();
    } else {
      return null;
    }

    final boundaryOk = validateBoundary(raw: raw, proofBoundary: proofBoundary);

    final pass =
        nativePass &&
        boundaryOk &&
        totalLanes == expectedTotalLanes &&
        passedLanes == expectedPassedLanes;

    return VGPreviewSurfaceSinkNodeSmokeReport(
      pass: pass,
      nativePass: nativePass,
      boundaryOk: boundaryOk,
      raw: raw,
      proofBoundary: proofBoundary,
      totalLanes: totalLanes,
      passedLanes: passedLanes,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGPreviewSurfaceSinkNodeSmokeReport &&
        other.pass == pass &&
        other.nativePass == nativePass &&
        other.boundaryOk == boundaryOk &&
        other.raw == raw &&
        other.proofBoundary == proofBoundary &&
        other.totalLanes == totalLanes &&
        other.passedLanes == passedLanes;
  }

  @override
  int get hashCode => Object.hash(
    pass,
    nativePass,
    boundaryOk,
    raw,
    proofBoundary,
    totalLanes,
    passedLanes,
  );

  @override
  String toString() =>
      'VGPreviewSurfaceSinkNodeSmokeReport('
      'pass: $pass, '
      'nativePass: $nativePass, '
      'boundaryOk: $boundaryOk, '
      'raw: $raw, '
      'proofBoundary: $proofBoundary, '
      'totalLanes: $totalLanes, '
      'passedLanes: $passedLanes)';
}

/// Runner for the Phase 1 PreviewSurfaceSinkNode smoke diagnostic route.
class VGPreviewSurfaceSinkNodeSmokeRunner {
  const VGPreviewSurfaceSinkNodeSmokeRunner({
    this.channel = const MethodChannel('vanguard_media_engine'),
  });

  /// Default MethodChannel used for route invocation.
  final MethodChannel channel;

  /// Invokes the native route and returns a validated [VGPreviewSurfaceSinkNodeSmokeReport].
  ///
  /// Throws [StateError] if the result map from the native route is invalid or
  /// cannot be parsed.
  Future<VGPreviewSurfaceSinkNodeSmokeReport> runSmoke({
    MethodChannel? channel,
  }) async {
    final effectiveChannel = channel ?? this.channel;
    final result = await effectiveChannel.invokeMethod<Object?>(
      VGPreviewSurfaceSinkNodeSmokeReport.methodName,
    );

    final report = VGPreviewSurfaceSinkNodeSmokeReport.fromMap(result);
    if (report == null) {
      throw StateError(
        'Invalid smoke report map returned from native route '
        '${VGPreviewSurfaceSinkNodeSmokeReport.methodName}: $result',
      );
    }
    return report;
  }
}
