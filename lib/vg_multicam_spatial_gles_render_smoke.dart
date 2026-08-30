// vg_multicam_spatial_gles_render_smoke.dart
// vanguard_media_engine — P3-MULTICAM-NODE: Android True-DAG Phase 3
// GLES-first spatial multi-texture diagnostic render pass smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke` and
// `disposeAndroidDagPhase3MultiCamSpatialGlesRenderSmoke` MethodChannel routes.
// Diagnostic-only — validates native GLES spatial composite render passes
// (top/bottom split, left/right split, top-left PiP, free-floating PiP),
// input validation (invalid handle, out-of-bounds rect), readback verification,
// sentinel clear, and full EGL/GLES lifecycle teardown on a Flutter SurfaceProducer.
// No Camera2, no Vulkan, no OES proof, no opacity, no corner radius, no recording,
// no export, and no product/editor UI.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 3 MultiCam spatial GLES render smoke harness.
enum VGMultiCamSpatialGlesRenderSmokeDecision {
  /// All native spatial GLES composite assertions and readback checks passed.
  pass,

  /// One or more native spatial GLES assertions failed.
  fail,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw native/Kotlin decision string to the matching enum value,
  /// falling back to [harnessException] for unrecognised/missing values.
  static VGMultiCamSpatialGlesRenderSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGMultiCamSpatialGlesRenderSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGMultiCamSpatialGlesRenderSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGMultiCamSpatialGlesRenderSmokeDecision.fail;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGMultiCamSpatialGlesRenderSmokeDecision.harnessException;
    }
    for (final value in VGMultiCamSpatialGlesRenderSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGMultiCamSpatialGlesRenderSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGMultiCamSpatialGlesRenderSmokeReport.startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke]'s
/// completion callback, mirroring the native harness's result map.
@immutable
class VGMultiCamSpatialGlesRenderSmokeReport {
  const VGMultiCamSpatialGlesRenderSmokeReport({
    required this.pass,
    required this.decision,
    required this.raw,
    required this.proofBoundary,
    required this.metrics,
    this.lastError = '',
    this.textureId = -1,
    this.surfaceProducerReleased = false,
    this.width = 0,
    this.height = 0,
  });

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_multicam_spatial_gles_two_texture_layout_render_readback_only_no_vulkan_no_camera_no_oes_proof_no_opacity_no_corner_radius_no_recording_no_product';

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed lifecycle decision.
  final VGMultiCamSpatialGlesRenderSmokeDecision decision;

  /// Raw return string from native C++ smoke function.
  final String raw;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, String> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

  /// The Flutter `TextureRegistry.SurfaceProducer` texture id.
  final int textureId;

  /// Whether the Flutter `SurfaceProducer` has been released.
  final bool surfaceProducerReleased;

  /// Target surface width in pixels.
  final int width;

  /// Target surface height in pixels.
  final int height;

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  // ── Setup & Import Lanes ──

  /// Whether HardwareBuffer A descriptor query succeeded.
  bool get bufferADescribePass => metrics['bufferADescribe'] == 'success';

  /// Whether HardwareBuffer A pixel fill succeeded.
  bool get bufferAFillPass => metrics['bufferAFill'] == 'success';

  /// Whether HardwareBuffer B descriptor query succeeded.
  bool get bufferBDescribePass => metrics['bufferBDescribe'] == 'success';

  /// Whether HardwareBuffer B pixel fill succeeded.
  bool get bufferBFillPass => metrics['bufferBFill'] == 'success';

  /// Whether pre-initialization render rejection succeeded.
  bool get preInitLanePass => metrics['preInitLane'] == 'rejected_as_expected';

  /// Whether GLES backend initialization succeeded.
  bool get initializePass => metrics['initialize'] == 'success';

  /// Whether surface attachment succeeded.
  bool get attachPass => metrics['attach'] == 'success';

  /// Whether HardwareBuffer A import into GLES succeeded.
  bool get importBufferAPass => metrics['importBufferA'] == 'success';

  /// Whether HardwareBuffer B import into GLES succeeded.
  bool get importBufferBPass => metrics['importBufferB'] == 'success';

  // ── Validation / Error Rejection Lanes ──

  /// Whether invalid buffer handle rejection succeeded.
  bool get invalidHandleLanePass =>
      metrics['invalidHandleLane'] == 'rejected_as_expected';

  /// Whether invalid out-of-bounds layout rect rejection succeeded.
  bool get invalidRectLanePass =>
      metrics['invalidRectLane'] == 'rejected_as_expected';

  // ── Spatial Composite Render Lanes ──

  /// Whether top/bottom split layout render and readback assertions passed.
  bool get topBottomSplitPass => metrics['topBottomSplitOk'] == 'true';

  /// Whether left/right split layout render and readback assertions passed.
  bool get leftRightSplitPass => metrics['leftRightSplitOk'] == 'true';

  /// Whether top-left PiP layout render and quadrant readback assertions passed.
  bool get pipTopLeftPass => metrics['pipTopLeftOk'] == 'true';

  /// Whether free-floating PiP layout render and readback assertions passed.
  bool get pipFreeFloatingPass => metrics['pipFreeFloatingOk'] == 'true';

  /// Whether sentinel clear prevented false-positive green color matches.
  bool get sentinelClearPass => metrics['sentinelClearOk'] == 'true';

  /// Whether final presentation render to the Flutter surface succeeded.
  bool get presentCompositePass => metrics['presentComposite'] == 'success';

  // ── Release & Teardown Lanes ──

  /// Whether HardwareBuffer A release succeeded.
  bool get releaseBufferAPass => metrics['releaseBufferA'] == 'success';

  /// Whether HardwareBuffer B release succeeded.
  bool get releaseBufferBPass => metrics['releaseBufferB'] == 'success';

  /// Whether HardwareBuffer A is confirmed released and no longer in the backend.
  bool get hasAAfterReleasePass => metrics['hasAAfterRelease'] == 'false';

  /// Whether HardwareBuffer B is confirmed released and no longer in the backend.
  bool get hasBAfterReleasePass => metrics['hasBAfterRelease'] == 'false';

  /// Whether post-release render rejection with released handles succeeded.
  bool get postReleaseLanePass =>
      metrics['postReleaseLane'] == 'rejected_as_expected';

  /// Whether surface detachment succeeded.
  bool get detachPass => metrics['detach'] == 'success';

  /// Whether backend shutdown succeeded.
  bool get shutdownPass => metrics['shutdown'] == 'success';

  /// Whether secondary idempotent shutdown succeeded.
  bool get idempotentShutdownPass => metrics['idempotentShutdown'] == 'success';

  /// Whether all native diagnostic lanes passed.
  bool get allNativeLanesPass =>
      bufferADescribePass &&
      bufferAFillPass &&
      bufferBDescribePass &&
      bufferBFillPass &&
      preInitLanePass &&
      initializePass &&
      attachPass &&
      importBufferAPass &&
      importBufferBPass &&
      invalidHandleLanePass &&
      invalidRectLanePass &&
      topBottomSplitPass &&
      leftRightSplitPass &&
      pipTopLeftPass &&
      pipFreeFloatingPass &&
      sentinelClearPass &&
      presentCompositePass &&
      releaseBufferAPass &&
      releaseBufferBPass &&
      hasAAfterReleasePass &&
      hasBAfterReleasePass &&
      postReleaseLanePass &&
      detachPass &&
      shutdownPass &&
      idempotentShutdownPass;

  /// Convenience getter for whether [decision] is [VGMultiCamSpatialGlesRenderSmokeDecision.pass].
  bool get isPass => decision == VGMultiCamSpatialGlesRenderSmokeDecision.pass;

  /// Convenience getter for whether [decision] is [VGMultiCamSpatialGlesRenderSmokeDecision.fail].
  bool get isFail => decision == VGMultiCamSpatialGlesRenderSmokeDecision.fail;

  /// Convenience getter for whether [decision] is [VGMultiCamSpatialGlesRenderSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGMultiCamSpatialGlesRenderSmokeDecision.harnessException;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGMultiCamSpatialGlesRenderSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGMultiCamSpatialGlesRenderSmokeReport(
        pass: false,
        decision: VGMultiCamSpatialGlesRenderSmokeDecision.harnessException,
        raw: raw?.toString() ?? '',
        proofBoundary: '',
        metrics: const <String, String>{'reason': 'native_result_not_a_map'},
        lastError: 'native_result_not_a_map',
        textureId: -1,
        surfaceProducerReleased: false,
        width: 0,
        height: 0,
      );
    }

    final rawString = (raw['raw'] as String?) ?? '';
    final proofBoundary = (raw['proofBoundary'] as String?) ?? '';
    final lastError = (raw['lastError'] as String?) ?? '';
    final textureId = (raw['textureId'] as num?)?.toInt() ?? -1;
    final surfaceProducerReleased =
        raw['surfaceProducerReleased'] as bool? ?? false;
    final width = (raw['width'] as num?)?.toInt() ?? 0;
    final height = (raw['height'] as num?)?.toInt() ?? 0;

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

    final pass = raw['pass'] as bool? ?? rawString.startsWith('status=PASS;');
    final decision = raw['decision'] != null
        ? VGMultiCamSpatialGlesRenderSmokeDecision.fromRaw(raw['decision'])
        : (pass
              ? VGMultiCamSpatialGlesRenderSmokeDecision.pass
              : VGMultiCamSpatialGlesRenderSmokeDecision.fail);

    return VGMultiCamSpatialGlesRenderSmokeReport(
      pass: pass,
      decision: decision,
      raw: rawString,
      proofBoundary: proofBoundary,
      metrics: Map<String, String>.unmodifiable(metrics),
      lastError: lastError,
      textureId: textureId,
      surfaceProducerReleased: surfaceProducerReleased,
      width: width,
      height: height,
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
      'lastError': lastError,
      'textureId': textureId,
      'surfaceProducerReleased': surfaceProducerReleased,
      'width': width,
      'height': height,
    };
  }

  static const String _startMethod =
      'startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke';
  static const String _disposeMethod =
      'disposeAndroidDagPhase3MultiCamSpatialGlesRenderSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Starts the Android True-DAG Phase 3 MultiCam spatial GLES render smoke harness.
  ///
  /// Launches the native diagnostic spatial render pass on a background thread
  /// and returns a record containing the allocated Flutter [textureId], [width],
  /// and [height].
  ///
  /// The full [VGMultiCamSpatialGlesRenderSmokeReport] is delivered asynchronously via
  /// `onAndroidDagPhase3MultiCamSpatialGlesRenderSmokeComplete`.
  ///
  /// [width] and [height] default to 128x128.
  /// [channel] may be injected for testing; defaults to `vanguard_media_engine`.
  static Future<({int textureId, int width, int height})>
  startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke({
    int width = 128,
    int height = 128,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final raw = await ch.invokeMethod<Object?>(_startMethod, <String, Object?>{
      'width': width,
      'height': height,
    });
    final map = raw is Map ? raw : const <Object?, Object?>{};
    final textureId = (map['textureId'] as num?)?.toInt() ?? -1;
    final w = (map['width'] as num?)?.toInt() ?? width;
    final h = (map['height'] as num?)?.toInt() ?? height;
    return (textureId: textureId, width: w, height: h);
  }

  /// Disposes the active spatial GLES render smoke run for [textureId].
  ///
  /// Requests cancellation if still running and releases the Flutter SurfaceProducer.
  /// Returns `true` if `surfaceProducerReleased` was confirmed by native coordinator.
  ///
  /// [channel] may be injected for testing; defaults to `vanguard_media_engine`.
  static Future<bool> disposeAndroidDagPhase3MultiCamSpatialGlesRenderSmoke({
    required int textureId,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final raw = await ch.invokeMethod<Object?>(
      _disposeMethod,
      <String, Object?>{'textureId': textureId},
    );
    final map = raw is Map ? raw : const <Object?, Object?>{};
    return map['surfaceProducerReleased'] as bool? ?? false;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGMultiCamSpatialGlesRenderSmokeReport &&
        other.pass == pass &&
        other.decision == decision &&
        other.raw == raw &&
        other.proofBoundary == proofBoundary &&
        mapEquals(other.metrics, metrics) &&
        other.lastError == lastError &&
        other.textureId == textureId &&
        other.surfaceProducerReleased == surfaceProducerReleased &&
        other.width == width &&
        other.height == height;
  }

  @override
  int get hashCode => Object.hash(
    pass,
    decision,
    raw,
    proofBoundary,
    _stableMapHash(metrics),
    lastError,
    textureId,
    surfaceProducerReleased,
    width,
    height,
  );

  static int _stableMapHash(Map<String, String> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGMultiCamSpatialGlesRenderSmokeReport('
      'pass: $pass, '
      'decision: $decision, '
      'raw: $raw, '
      'proofBoundary: $proofBoundary, '
      'metrics: $metrics, '
      'lastError: $lastError, '
      'textureId: $textureId, '
      'surfaceProducerReleased: $surfaceProducerReleased, '
      'width: $width, '
      'height: $height)';
}
