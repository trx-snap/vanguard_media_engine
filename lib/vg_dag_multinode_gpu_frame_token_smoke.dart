// vg_dag_multinode_gpu_frame_token_smoke.dart
// vanguard_media_engine -- P1-DAG-MULTINODE-GPU-FRAME-TOKEN-CONTRACT
// Pure Dart smoke wrapper and physical entrypoint for platform-neutral,
// non-owning GPU frame token identity/binding contract verification.
//
// Proof boundary:
//   platform_neutral_gpu_frame_token_binding_contract_diagnostic_only_no_os_resource_ownership_no_render_no_gpu_transport_no_product_app_editor_wiring
//
// Diagnostic-only: no OS/GPU resource ownership, no rendering, no GPU
// transport, and no product/editor/app wiring.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Canonical MethodChannel method name for the Phase 1 DagMultinodeGpuFrameToken smoke route.
const String kDagMultinodeGpuFrameTokenMethodName =
    'runAndroidDagPhase1DagMultinodeGpuFrameTokenSmoke';

/// Canonical proof boundary required for Phase 1 DagMultinodeGpuFrameToken verification.
const String kDagMultinodeGpuFrameTokenProofBoundary =
    'platform_neutral_gpu_frame_token_binding_contract_diagnostic_only_no_os_resource_'
    'ownership_no_render_no_gpu_transport_no_product_app_editor_wiring';

/// Physical smoke execution start marker.
const String kDagMultinodeGpuFrameTokenStartMarker =
    'ANDROID_DAG_PHASE1_DAG_MULTINODE_GPU_FRAME_TOKEN_PHYSICAL_SMOKE_START';

/// Physical smoke execution pass marker.
const String kDagMultinodeGpuFrameTokenPassMarker =
    'ANDROID_DAG_PHASE1_DAG_MULTINODE_GPU_FRAME_TOKEN_PHYSICAL_SMOKE_PASS';

/// Physical smoke execution fail marker.
const String kDagMultinodeGpuFrameTokenFailMarker =
    'ANDROID_DAG_PHASE1_DAG_MULTINODE_GPU_FRAME_TOKEN_PHYSICAL_SMOKE_FAIL';

/// JSON payload log prefix for physical smoke reporting.
const String kDagMultinodeGpuFrameTokenJsonPrefix =
    'ANDROID_DAG_PHASE1_DAG_MULTINODE_GPU_FRAME_TOKEN_JSON:';

/// Expected total lanes executed by the native smoke test.
const int kDagMultinodeGpuFrameTokenExpectedTotalLanes = 10;

/// Expected passed lanes executed by the native smoke test.
const int kDagMultinodeGpuFrameTokenExpectedPassedLanes = 10;

/// Immutable report model for Phase 1 DagMultinodeGpuFrameToken smoke test results.
@immutable
class VGDagMultinodeGpuFrameTokenSmokeReport {
  const VGDagMultinodeGpuFrameTokenSmokeReport({
    required this.pass,
    required this.nativePass,
    required this.boundaryOk,
    required this.raw,
    required this.proofBoundary,
    required this.totalLanes,
    required this.passedLanes,
  });

  /// Canonical MethodChannel method name.
  static const String methodName = kDagMultinodeGpuFrameTokenMethodName;

  /// Required proof boundary constant.
  static const String requiredProofBoundary =
      kDagMultinodeGpuFrameTokenProofBoundary;

  /// Start marker string.
  static const String startMarker = kDagMultinodeGpuFrameTokenStartMarker;

  /// Pass marker string.
  static const String passMarker = kDagMultinodeGpuFrameTokenPassMarker;

  /// Fail marker string.
  static const String failMarker = kDagMultinodeGpuFrameTokenFailMarker;

  /// JSON output prefix string.
  static const String jsonPrefix = kDagMultinodeGpuFrameTokenJsonPrefix;

  /// Expected total lanes.
  static const int expectedTotalLanes =
      kDagMultinodeGpuFrameTokenExpectedTotalLanes;

  /// Expected passed lanes.
  static const int expectedPassedLanes =
      kDagMultinodeGpuFrameTokenExpectedPassedLanes;

  /// Required boundary tokens that must all be present in raw/proofBoundary combined.
  static const List<String> requiredBoundaryTokens = <String>[
    'gpu_frame_token_binding_contract',
    'diagnostic_only',
    'no_os_resource_ownership',
    'no_render',
    'no_gpu_transport',
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
  static VGDagMultinodeGpuFrameTokenSmokeReport? fromMap(Object? data) {
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

    return VGDagMultinodeGpuFrameTokenSmokeReport(
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
    return other is VGDagMultinodeGpuFrameTokenSmokeReport &&
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
      'VGDagMultinodeGpuFrameTokenSmokeReport('
      'pass: $pass, '
      'nativePass: $nativePass, '
      'boundaryOk: $boundaryOk, '
      'raw: $raw, '
      'proofBoundary: $proofBoundary, '
      'totalLanes: $totalLanes, '
      'passedLanes: $passedLanes)';
}

/// Runner for the Phase 1 DagMultinodeGpuFrameToken smoke diagnostic route.
class VGDagMultinodeGpuFrameTokenSmokeRunner {
  const VGDagMultinodeGpuFrameTokenSmokeRunner({
    this.channel = const MethodChannel('vanguard_media_engine'),
  });

  /// Default MethodChannel used for route invocation.
  final MethodChannel channel;

  /// Invokes the native route and returns a validated [VGDagMultinodeGpuFrameTokenSmokeReport].
  ///
  /// Throws [StateError] if the result map from the native route is invalid or
  /// cannot be parsed.
  Future<VGDagMultinodeGpuFrameTokenSmokeReport> runSmoke({
    MethodChannel? channel,
  }) async {
    final effectiveChannel = channel ?? this.channel;
    final result = await effectiveChannel.invokeMethod<Object?>(
      VGDagMultinodeGpuFrameTokenSmokeReport.methodName,
    );

    final report = VGDagMultinodeGpuFrameTokenSmokeReport.fromMap(result);
    if (report == null) {
      throw StateError(
        'Invalid smoke report map returned from native route '
        '${VGDagMultinodeGpuFrameTokenSmokeReport.methodName}: $result',
      );
    }
    return report;
  }
}
