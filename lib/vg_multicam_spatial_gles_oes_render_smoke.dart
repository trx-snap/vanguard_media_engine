// vg_multicam_spatial_gles_oes_render_smoke.dart
// vanguard_media_engine -- P3-MULTICAM-NODE-GLES-OES-SPATIAL-RENDER: Android
// True-DAG Phase 3 GLES-first spatial multi-texture diagnostic render pass
// OES smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke` and
// `disposeAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke` MethodChannel
// routes. Bounded extension of the existing RGBA-only spatial route
// (`vg_multicam_spatial_gles_render_smoke.dart`): additionally imports two
// YCBCR_420_888 GPU-sampled AHardwareBuffer instances (GL_TEXTURE_EXTERNAL_OES)
// and exercises 2D+OES, OES+2D, and OES+OES spatial composite lane
// permutations, input validation (invalid handle, out-of-bounds rect),
// release/post-release invalid-handle behavior, and full EGL/GLES lifecycle
// teardown on a Flutter SurfaceProducer.
//
// OES lanes assert render/readback success and resolved texture target only
// -- never deterministic color content, since the YCBCR buffers are never
// CPU-filled. No Camera2, no Vulkan, no opacity, no corner radius, no
// recording, no export, and no product/editor UI.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 3 MultiCam spatial GLES OES render smoke harness.
enum VGMultiCamSpatialGlesOesRenderSmokeDecision {
  /// All native spatial GLES OES composite assertions and readback checks passed.
  pass,

  /// One or more native spatial GLES OES assertions failed.
  fail,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw native/Kotlin decision string to the matching enum value,
  /// falling back to [harnessException] for unrecognised/missing values.
  static VGMultiCamSpatialGlesOesRenderSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGMultiCamSpatialGlesOesRenderSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGMultiCamSpatialGlesOesRenderSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGMultiCamSpatialGlesOesRenderSmokeDecision.fail;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGMultiCamSpatialGlesOesRenderSmokeDecision.harnessException;
    }
    for (final value in VGMultiCamSpatialGlesOesRenderSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGMultiCamSpatialGlesOesRenderSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGMultiCamSpatialGlesOesRenderSmokeReport.startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke]'s
/// completion callback, mirroring the native harness's result map.
@immutable
class VGMultiCamSpatialGlesOesRenderSmokeReport {
  const VGMultiCamSpatialGlesOesRenderSmokeReport({
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
      'native_multicam_spatial_gles_oes_texture_layout_render_readback_only_no_vulkan_no_camera_no_opacity_no_corner_radius_no_recording_no_product';

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed lifecycle decision.
  final VGMultiCamSpatialGlesOesRenderSmokeDecision decision;

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

  // -- Setup & Import Lanes --

  /// Whether the RGBA HardwareBuffer A descriptor query succeeded.
  bool get rgbaADescribePass => metrics['rgbaADescribe'] == 'success';

  /// Whether the RGBA HardwareBuffer A pixel fill succeeded.
  bool get rgbaAFillPass => metrics['rgbaAFill'] == 'success';

  /// Whether the RGBA HardwareBuffer B descriptor query succeeded.
  bool get rgbaBDescribePass => metrics['rgbaBDescribe'] == 'success';

  /// Whether the RGBA HardwareBuffer B pixel fill succeeded.
  bool get rgbaBFillPass => metrics['rgbaBFill'] == 'success';

  /// Whether the YCBCR HardwareBuffer A descriptor query succeeded.
  bool get ycbcrADescribePass => metrics['ycbcrADescribe'] == 'success';

  /// Whether the YCBCR HardwareBuffer A format is YCBCR_420_888.
  bool get ycbcrAFormatIs420888 => metrics['ycbcrAFormatIs420888'] == 'true';

  /// Whether the YCBCR HardwareBuffer B descriptor query succeeded.
  bool get ycbcrBDescribePass => metrics['ycbcrBDescribe'] == 'success';

  /// Whether the YCBCR HardwareBuffer B format is YCBCR_420_888.
  bool get ycbcrBFormatIs420888 => metrics['ycbcrBFormatIs420888'] == 'true';

  /// Whether pre-initialization render rejection succeeded.
  bool get preInitLanePass => metrics['preInitLane'] == 'rejected_as_expected';

  /// Whether GLES backend initialization succeeded.
  bool get initializePass => metrics['initialize'] == 'success';

  /// Whether surface attachment succeeded.
  bool get attachPass => metrics['attach'] == 'success';

  /// Whether RGBA HardwareBuffer A import into GLES (GL_TEXTURE_2D) succeeded.
  bool get importRgbaAPass => metrics['importRgbaA'] == 'success';

  /// Whether RGBA HardwareBuffer B import into GLES (GL_TEXTURE_2D) succeeded.
  bool get importRgbaBPass => metrics['importRgbaB'] == 'success';

  /// Whether YCBCR HardwareBuffer A import into GLES (GL_TEXTURE_EXTERNAL_OES) succeeded.
  bool get importYcbcrAPass => metrics['importYcbcrA'] == 'success';

  /// Whether YCBCR HardwareBuffer B import into GLES (GL_TEXTURE_EXTERNAL_OES) succeeded.
  bool get importYcbcrBPass => metrics['importYcbcrB'] == 'success';

  // -- Validation / Error Rejection Lanes --

  /// Whether invalid buffer handle rejection succeeded.
  bool get invalidHandleLanePass =>
      metrics['invalidHandleLane'] == 'rejected_as_expected';

  /// Whether invalid out-of-bounds layout rect rejection succeeded (asserted
  /// against an OES+OES handle pair).
  bool get invalidRectLanePass =>
      metrics['invalidRectLane'] == 'rejected_as_expected';

  // -- OES Spatial Composite Render Lanes --

  /// Whether the 2D-primary + OES-secondary spatial composite lane passed
  /// (render/readback success and resolved OES target only).
  bool get twoDOesPass =>
      metrics['twoDOesOk'] == 'true' && metrics['twoDOesTargetOk'] == 'true';

  /// Whether the OES-primary + 2D-secondary spatial composite lane passed
  /// (render/readback success and resolved OES target only).
  bool get oesTwoDPass =>
      metrics['oesTwoDOk'] == 'true' && metrics['oesTwoDTargetOk'] == 'true';

  /// Whether the OES-primary + OES-secondary spatial composite lane passed
  /// (render/readback success and resolved OES targets only).
  bool get oesOesPass =>
      metrics['oesOesOk'] == 'true' && metrics['oesOesTargetOk'] == 'true';

  /// Whether the final OES+OES presentation render to the Flutter surface succeeded.
  bool get presentOesOesPass => metrics['presentOesOes'] == 'success';

  // -- Release & Teardown Lanes --

  /// Whether RGBA HardwareBuffer A release succeeded.
  bool get releaseRgbaAPass => metrics['releaseRgbaA'] == 'success';

  /// Whether RGBA HardwareBuffer B release succeeded.
  bool get releaseRgbaBPass => metrics['releaseRgbaB'] == 'success';

  /// Whether YCBCR HardwareBuffer A release succeeded.
  bool get releaseYcbcrAPass => metrics['releaseYcbcrA'] == 'success';

  /// Whether YCBCR HardwareBuffer B release succeeded.
  bool get releaseYcbcrBPass => metrics['releaseYcbcrB'] == 'success';

  /// Whether RGBA HardwareBuffer A is confirmed released and no longer in the backend.
  bool get hasRgbaAAfterReleasePass =>
      metrics['hasRgbaAAfterRelease'] == 'false';

  /// Whether RGBA HardwareBuffer B is confirmed released and no longer in the backend.
  bool get hasRgbaBAfterReleasePass =>
      metrics['hasRgbaBAfterRelease'] == 'false';

  /// Whether YCBCR HardwareBuffer A is confirmed released and no longer in the backend.
  bool get hasYcbcrAAfterReleasePass =>
      metrics['hasYcbcrAAfterRelease'] == 'false';

  /// Whether YCBCR HardwareBuffer B is confirmed released and no longer in the backend.
  bool get hasYcbcrBAfterReleasePass =>
      metrics['hasYcbcrBAfterRelease'] == 'false';

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
      rgbaADescribePass &&
      rgbaAFillPass &&
      rgbaBDescribePass &&
      rgbaBFillPass &&
      ycbcrADescribePass &&
      ycbcrAFormatIs420888 &&
      ycbcrBDescribePass &&
      ycbcrBFormatIs420888 &&
      preInitLanePass &&
      initializePass &&
      attachPass &&
      importRgbaAPass &&
      importRgbaBPass &&
      importYcbcrAPass &&
      importYcbcrBPass &&
      invalidHandleLanePass &&
      invalidRectLanePass &&
      twoDOesPass &&
      oesTwoDPass &&
      oesOesPass &&
      presentOesOesPass &&
      releaseRgbaAPass &&
      releaseRgbaBPass &&
      releaseYcbcrAPass &&
      releaseYcbcrBPass &&
      hasRgbaAAfterReleasePass &&
      hasRgbaBAfterReleasePass &&
      hasYcbcrAAfterReleasePass &&
      hasYcbcrBAfterReleasePass &&
      postReleaseLanePass &&
      detachPass &&
      shutdownPass &&
      idempotentShutdownPass;

  /// Convenience getter for whether [decision] is [VGMultiCamSpatialGlesOesRenderSmokeDecision.pass].
  bool get isPass =>
      decision == VGMultiCamSpatialGlesOesRenderSmokeDecision.pass;

  /// Convenience getter for whether [decision] is [VGMultiCamSpatialGlesOesRenderSmokeDecision.fail].
  bool get isFail =>
      decision == VGMultiCamSpatialGlesOesRenderSmokeDecision.fail;

  /// Convenience getter for whether [decision] is [VGMultiCamSpatialGlesOesRenderSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGMultiCamSpatialGlesOesRenderSmokeDecision.harnessException;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGMultiCamSpatialGlesOesRenderSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGMultiCamSpatialGlesOesRenderSmokeReport(
        pass: false,
        decision: VGMultiCamSpatialGlesOesRenderSmokeDecision.harnessException,
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
        ? VGMultiCamSpatialGlesOesRenderSmokeDecision.fromRaw(raw['decision'])
        : (pass
              ? VGMultiCamSpatialGlesOesRenderSmokeDecision.pass
              : VGMultiCamSpatialGlesOesRenderSmokeDecision.fail);

    return VGMultiCamSpatialGlesOesRenderSmokeReport(
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
      'startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke';
  static const String _disposeMethod =
      'disposeAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Starts the Android True-DAG Phase 3 MultiCam spatial GLES OES render smoke harness.
  ///
  /// Launches the native diagnostic spatial OES render pass on a background
  /// thread and returns a record containing the allocated Flutter
  /// [textureId], [width], and [height].
  ///
  /// The full [VGMultiCamSpatialGlesOesRenderSmokeReport] is delivered
  /// asynchronously via `onAndroidDagPhase3MultiCamSpatialGlesOesRenderSmokeComplete`.
  ///
  /// [width] and [height] default to 128x128.
  /// [channel] may be injected for testing; defaults to `vanguard_media_engine`.
  static Future<({int textureId, int width, int height})>
  startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke({
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

  /// Disposes the active spatial GLES OES render smoke run for [textureId].
  ///
  /// Requests cancellation if still running and releases the Flutter SurfaceProducer.
  /// Returns `true` if `surfaceProducerReleased` was confirmed by native coordinator.
  ///
  /// [channel] may be injected for testing; defaults to `vanguard_media_engine`.
  static Future<bool> disposeAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke({
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
    return other is VGMultiCamSpatialGlesOesRenderSmokeReport &&
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
      'VGMultiCamSpatialGlesOesRenderSmokeReport('
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
