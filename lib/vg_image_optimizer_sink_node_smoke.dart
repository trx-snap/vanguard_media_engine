// vg_image_optimizer_sink_node_smoke.dart
// vanguard_media_engine -- P5-IMAGE-OPTIMIZER-SINK-NODE-A
// Pure Dart smoke wrapper and physical entrypoint for platform-neutral
// ImageOptimizerSinkNode logical DAG sink node verification.
//
// Proof boundary:
//   platform_neutral_image_optimizer_sink_node_logical_dag_sink_no_decode_no_downscale_no_encode_no_file_io_no_gpu_lifecycle_no_product_app_editor_wiring
//
// Diagnostic-only: no decoded pixels, Bitmap/ImageDecoder lifecycle, JPEG/
// PNG/HEIC encoder lifecycle, output file/path/fd, GPU texture/sampler/
// lifecycle, Android lifecycle, MediaCodec, thread, or product/editor/app
// wiring.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Canonical MethodChannel method name for the Phase 5
/// ImageOptimizerSinkNode smoke route.
const String kImageOptimizerSinkNodeMethodName =
    'runAndroidDagPhase5ImageOptimizerSinkNodeSmoke';

/// Canonical proof boundary required for Phase 5 ImageOptimizerSinkNode
/// verification.
const String kImageOptimizerSinkNodeProofBoundary =
    'platform_neutral_image_optimizer_sink_node_logical_dag_sink_no_decode_no_downscale_no_encode_no_file_io_no_gpu_lifecycle_no_product_app_editor_wiring';

/// Physical smoke execution start marker.
const String kImageOptimizerSinkNodeStartMarker =
    'ANDROID_DAG_PHASE5_IMAGE_OPTIMIZER_SINK_NODE_PHYSICAL_SMOKE_START';

/// Physical smoke execution pass marker.
const String kImageOptimizerSinkNodePassMarker =
    'ANDROID_DAG_PHASE5_IMAGE_OPTIMIZER_SINK_NODE_PHYSICAL_SMOKE_PASS';

/// Physical smoke execution fail marker.
const String kImageOptimizerSinkNodeFailMarker =
    'ANDROID_DAG_PHASE5_IMAGE_OPTIMIZER_SINK_NODE_PHYSICAL_SMOKE_FAIL';

/// JSON payload log prefix for physical smoke reporting.
const String kImageOptimizerSinkNodeJsonPrefix =
    'ANDROID_DAG_PHASE5_IMAGE_OPTIMIZER_SINK_NODE_JSON:';

/// Expected total lanes executed by the native smoke test.
const int kImageOptimizerSinkNodeExpectedTotalLanes = 15;

/// Expected passed lanes executed by the native smoke test.
const int kImageOptimizerSinkNodeExpectedPassedLanes = 15;

/// Immutable report model for Phase 5 ImageOptimizerSinkNode smoke test
/// results.
@immutable
class VGImageOptimizerSinkNodeSmokeReport {
  const VGImageOptimizerSinkNodeSmokeReport({
    required this.pass,
    required this.nativePass,
    required this.boundaryOk,
    required this.raw,
    required this.proofBoundary,
    required this.totalLanes,
    required this.passedLanes,
  });

  /// Canonical MethodChannel method name.
  static const String methodName = kImageOptimizerSinkNodeMethodName;

  /// Required proof boundary constant.
  static const String requiredProofBoundary =
      kImageOptimizerSinkNodeProofBoundary;

  /// Start marker string.
  static const String startMarker = kImageOptimizerSinkNodeStartMarker;

  /// Pass marker string.
  static const String passMarker = kImageOptimizerSinkNodePassMarker;

  /// Fail marker string.
  static const String failMarker = kImageOptimizerSinkNodeFailMarker;

  /// JSON output prefix string.
  static const String jsonPrefix = kImageOptimizerSinkNodeJsonPrefix;

  /// Expected total lanes.
  static const int expectedTotalLanes =
      kImageOptimizerSinkNodeExpectedTotalLanes;

  /// Expected passed lanes.
  static const int expectedPassedLanes =
      kImageOptimizerSinkNodeExpectedPassedLanes;

  /// Required boundary tokens that must all be present in raw/proofBoundary combined.
  static const List<String> requiredBoundaryTokens = <String>[
    'platform_neutral',
    'image_optimizer_sink_node',
    'logical_dag_sink',
    'no_decode',
    'no_downscale',
    'no_encode',
    'no_file_io',
    'no_gpu_lifecycle',
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
  static VGImageOptimizerSinkNodeSmokeReport? fromMap(Object? data) {
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

    return VGImageOptimizerSinkNodeSmokeReport(
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
    return other is VGImageOptimizerSinkNodeSmokeReport &&
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
      'VGImageOptimizerSinkNodeSmokeReport('
      'pass: $pass, '
      'nativePass: $nativePass, '
      'boundaryOk: $boundaryOk, '
      'raw: $raw, '
      'proofBoundary: $proofBoundary, '
      'totalLanes: $totalLanes, '
      'passedLanes: $passedLanes)';
}

/// Runner for the Phase 5 ImageOptimizerSinkNode smoke diagnostic route.
class VGImageOptimizerSinkNodeSmokeRunner {
  const VGImageOptimizerSinkNodeSmokeRunner({
    this.channel = const MethodChannel('vanguard_media_engine'),
  });

  /// Default MethodChannel used for route invocation.
  final MethodChannel channel;

  /// Invokes the native route and returns a validated
  /// [VGImageOptimizerSinkNodeSmokeReport].
  ///
  /// Throws [StateError] if the result map from the native route is invalid or
  /// cannot be parsed.
  Future<VGImageOptimizerSinkNodeSmokeReport> runSmoke({
    MethodChannel? channel,
  }) async {
    final effectiveChannel = channel ?? this.channel;
    final result = await effectiveChannel.invokeMethod<Object?>(
      VGImageOptimizerSinkNodeSmokeReport.methodName,
    );

    final report = VGImageOptimizerSinkNodeSmokeReport.fromMap(result);
    if (report == null) {
      throw StateError(
        'Invalid smoke report map returned from native route '
        '${VGImageOptimizerSinkNodeSmokeReport.methodName}: $result',
      );
    }
    return report;
  }
}
