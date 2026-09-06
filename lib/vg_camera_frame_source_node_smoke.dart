// vg_camera_frame_source_node_smoke.dart
// vanguard_media_engine -- P3-CAMERA-FRAME-SOURCE-NODE-A
// Pure Dart smoke wrapper and physical entrypoint for platform-neutral
// CameraFrameSourceNode logical DAG source node verification.
//
// Proof boundary:
//   platform_neutral_camera_frame_source_node_logical_dag_source_no_camera_hardware_ownership_no_android_lifecycle_no_product_app_editor_wiring
//
// Diagnostic-only: no Camera2/NDK capture session, no hardware buffer
// ownership, no rendering, no Android lifecycle, and no product/editor/app
// wiring.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Canonical MethodChannel method name for the Phase 3 CameraFrameSourceNode smoke route.
const String kCameraFrameSourceNodeMethodName =
    'runAndroidDagPhase3CameraFrameSourceNodeSmoke';

/// Canonical proof boundary required for Phase 3 CameraFrameSourceNode verification.
const String kCameraFrameSourceNodeProofBoundary =
    'platform_neutral_camera_frame_source_node_logical_dag_source_no_camera_hardware_ownership_no_android_lifecycle_no_product_app_editor_wiring';

/// Physical smoke execution start marker.
const String kCameraFrameSourceNodeStartMarker =
    'ANDROID_DAG_PHASE3_CAMERA_FRAME_SOURCE_NODE_PHYSICAL_SMOKE_START';

/// Physical smoke execution pass marker.
const String kCameraFrameSourceNodePassMarker =
    'ANDROID_DAG_PHASE3_CAMERA_FRAME_SOURCE_NODE_PHYSICAL_SMOKE_PASS';

/// Physical smoke execution fail marker.
const String kCameraFrameSourceNodeFailMarker =
    'ANDROID_DAG_PHASE3_CAMERA_FRAME_SOURCE_NODE_PHYSICAL_SMOKE_FAIL';

/// JSON payload log prefix for physical smoke reporting.
const String kCameraFrameSourceNodeJsonPrefix =
    'ANDROID_DAG_PHASE3_CAMERA_FRAME_SOURCE_NODE_JSON:';

/// Expected total lanes executed by the native smoke test.
const int kCameraFrameSourceNodeExpectedTotalLanes = 15;

/// Expected passed lanes executed by the native smoke test.
const int kCameraFrameSourceNodeExpectedPassedLanes = 15;

/// Immutable report model for Phase 3 CameraFrameSourceNode smoke test results.
@immutable
class VGCameraFrameSourceNodeSmokeReport {
  const VGCameraFrameSourceNodeSmokeReport({
    required this.pass,
    required this.nativePass,
    required this.boundaryOk,
    required this.raw,
    required this.proofBoundary,
    required this.totalLanes,
    required this.passedLanes,
  });

  /// Canonical MethodChannel method name.
  static const String methodName = kCameraFrameSourceNodeMethodName;

  /// Required proof boundary constant.
  static const String requiredProofBoundary =
      kCameraFrameSourceNodeProofBoundary;

  /// Start marker string.
  static const String startMarker = kCameraFrameSourceNodeStartMarker;

  /// Pass marker string.
  static const String passMarker = kCameraFrameSourceNodePassMarker;

  /// Fail marker string.
  static const String failMarker = kCameraFrameSourceNodeFailMarker;

  /// JSON output prefix string.
  static const String jsonPrefix = kCameraFrameSourceNodeJsonPrefix;

  /// Expected total lanes.
  static const int expectedTotalLanes =
      kCameraFrameSourceNodeExpectedTotalLanes;

  /// Expected passed lanes.
  static const int expectedPassedLanes =
      kCameraFrameSourceNodeExpectedPassedLanes;

  /// Required boundary tokens that must all be present in raw/proofBoundary combined.
  static const List<String> requiredBoundaryTokens = <String>[
    'platform_neutral',
    'camera_frame_source_node',
    'logical_dag_source',
    'no_camera_hardware_ownership',
    'no_android_lifecycle',
    'no_product_app_editor_wiring',
  ];

  /// Overall pass flag: true only when [nativePass] is true, [boundaryOk] is true,
  /// [totalLanes] == 15, and [passedLanes] == 15.
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
  /// [boundaryOk] is true, [totalLanes] == 15, and [passedLanes] == 15.
  static VGCameraFrameSourceNodeSmokeReport? fromMap(Object? data) {
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

    return VGCameraFrameSourceNodeSmokeReport(
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
    return other is VGCameraFrameSourceNodeSmokeReport &&
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
      'VGCameraFrameSourceNodeSmokeReport('
      'pass: $pass, '
      'nativePass: $nativePass, '
      'boundaryOk: $boundaryOk, '
      'raw: $raw, '
      'proofBoundary: $proofBoundary, '
      'totalLanes: $totalLanes, '
      'passedLanes: $passedLanes)';
}

/// Runner for the Phase 3 CameraFrameSourceNode smoke diagnostic route.
class VGCameraFrameSourceNodeSmokeRunner {
  const VGCameraFrameSourceNodeSmokeRunner({
    this.channel = const MethodChannel('vanguard_media_engine'),
  });

  /// Default MethodChannel used for route invocation.
  final MethodChannel channel;

  /// Invokes the native route and returns a validated [VGCameraFrameSourceNodeSmokeReport].
  ///
  /// Throws [StateError] if the result map from the native route is invalid or
  /// cannot be parsed.
  Future<VGCameraFrameSourceNodeSmokeReport> runSmoke({
    MethodChannel? channel,
  }) async {
    final effectiveChannel = channel ?? this.channel;
    final result = await effectiveChannel.invokeMethod<Object?>(
      VGCameraFrameSourceNodeSmokeReport.methodName,
    );

    final report = VGCameraFrameSourceNodeSmokeReport.fromMap(result);
    if (report == null) {
      throw StateError(
        'Invalid smoke report map returned from native route '
        '${VGCameraFrameSourceNodeSmokeReport.methodName}: $result',
      );
    }
    return report;
  }
}
