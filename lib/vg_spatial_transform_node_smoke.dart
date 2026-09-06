// vg_spatial_transform_node_smoke.dart
// vanguard_media_engine -- P5-SPATIAL-TRANSFORM-NODE-A
// Pure Dart smoke wrapper and physical entrypoint for platform-neutral
// SpatialTransformNode logical DAG processing node verification.
//
// Proof boundary:
//   platform_neutral_spatial_transform_node_logical_dag_transform_no_render_ownership_no_texture_ownership_no_gpu_lifecycle_no_product_app_editor_wiring
//
// Diagnostic-only: no renderer, shader, texture, decoder, Android
// lifecycle, or GPU object ownership, and no product/editor/app wiring.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Canonical MethodChannel method name for the Phase 5 SpatialTransformNode smoke route.
const String kSpatialTransformNodeMethodName =
    'runAndroidDagPhase5SpatialTransformNodeSmoke';

/// Canonical proof boundary required for Phase 5 SpatialTransformNode verification.
const String kSpatialTransformNodeProofBoundary =
    'platform_neutral_spatial_transform_node_logical_dag_transform_no_render_ownership_no_texture_ownership_no_gpu_lifecycle_no_product_app_editor_wiring';

/// Physical smoke execution start marker.
const String kSpatialTransformNodeStartMarker =
    'ANDROID_DAG_PHASE5_SPATIAL_TRANSFORM_NODE_PHYSICAL_SMOKE_START';

/// Physical smoke execution pass marker.
const String kSpatialTransformNodePassMarker =
    'ANDROID_DAG_PHASE5_SPATIAL_TRANSFORM_NODE_PHYSICAL_SMOKE_PASS';

/// Physical smoke execution fail marker.
const String kSpatialTransformNodeFailMarker =
    'ANDROID_DAG_PHASE5_SPATIAL_TRANSFORM_NODE_PHYSICAL_SMOKE_FAIL';

/// JSON payload log prefix for physical smoke reporting.
const String kSpatialTransformNodeJsonPrefix =
    'ANDROID_DAG_PHASE5_SPATIAL_TRANSFORM_NODE_JSON:';

/// Expected total lanes executed by the native smoke test.
const int kSpatialTransformNodeExpectedTotalLanes = 16;

/// Expected passed lanes executed by the native smoke test.
const int kSpatialTransformNodeExpectedPassedLanes = 16;

/// Immutable report model for Phase 5 SpatialTransformNode smoke test results.
@immutable
class VGSpatialTransformNodeSmokeReport {
  const VGSpatialTransformNodeSmokeReport({
    required this.pass,
    required this.nativePass,
    required this.boundaryOk,
    required this.raw,
    required this.proofBoundary,
    required this.totalLanes,
    required this.passedLanes,
  });

  /// Canonical MethodChannel method name.
  static const String methodName = kSpatialTransformNodeMethodName;

  /// Required proof boundary constant.
  static const String requiredProofBoundary =
      kSpatialTransformNodeProofBoundary;

  /// Start marker string.
  static const String startMarker = kSpatialTransformNodeStartMarker;

  /// Pass marker string.
  static const String passMarker = kSpatialTransformNodePassMarker;

  /// Fail marker string.
  static const String failMarker = kSpatialTransformNodeFailMarker;

  /// JSON output prefix string.
  static const String jsonPrefix = kSpatialTransformNodeJsonPrefix;

  /// Expected total lanes.
  static const int expectedTotalLanes = kSpatialTransformNodeExpectedTotalLanes;

  /// Expected passed lanes.
  static const int expectedPassedLanes =
      kSpatialTransformNodeExpectedPassedLanes;

  /// Required boundary tokens that must all be present in raw/proofBoundary combined.
  static const List<String> requiredBoundaryTokens = <String>[
    'platform_neutral',
    'spatial_transform_node',
    'logical_dag_transform',
    'no_render_ownership',
    'no_texture_ownership',
    'no_gpu_lifecycle',
    'no_product_app_editor_wiring',
  ];

  /// Overall pass flag: true only when [nativePass] is true, [boundaryOk] is true,
  /// [totalLanes] == 16, and [passedLanes] == 16.
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
  /// [boundaryOk] is true, [totalLanes] == 16, and [passedLanes] == 16.
  static VGSpatialTransformNodeSmokeReport? fromMap(Object? data) {
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

    return VGSpatialTransformNodeSmokeReport(
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
    return other is VGSpatialTransformNodeSmokeReport &&
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
      'VGSpatialTransformNodeSmokeReport('
      'pass: $pass, '
      'nativePass: $nativePass, '
      'boundaryOk: $boundaryOk, '
      'raw: $raw, '
      'proofBoundary: $proofBoundary, '
      'totalLanes: $totalLanes, '
      'passedLanes: $passedLanes)';
}

/// Runner for the Phase 5 SpatialTransformNode smoke diagnostic route.
class VGSpatialTransformNodeSmokeRunner {
  const VGSpatialTransformNodeSmokeRunner({
    this.channel = const MethodChannel('vanguard_media_engine'),
  });

  /// Default MethodChannel used for route invocation.
  final MethodChannel channel;

  /// Invokes the native route and returns a validated [VGSpatialTransformNodeSmokeReport].
  ///
  /// Throws [StateError] if the result map from the native route is invalid or
  /// cannot be parsed.
  Future<VGSpatialTransformNodeSmokeReport> runSmoke({
    MethodChannel? channel,
  }) async {
    final effectiveChannel = channel ?? this.channel;
    final result = await effectiveChannel.invokeMethod<Object?>(
      VGSpatialTransformNodeSmokeReport.methodName,
    );

    final report = VGSpatialTransformNodeSmokeReport.fromMap(result);
    if (report == null) {
      throw StateError(
        'Invalid smoke report map returned from native route '
        '${VGSpatialTransformNodeSmokeReport.methodName}: $result',
      );
    }
    return report;
  }
}
