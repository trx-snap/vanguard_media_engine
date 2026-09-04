// vg_multicam_dynamic_descriptor_spatial_render_smoke.dart
// vanguard_media_engine -- P3-MULTICAM-NODE-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER:
// Android True-DAG Phase 3 diagnostic proving a caller-supplied Dart layout
// descriptor map drives native GLES/OES spatial rendering end to end.
//
// Pure Dart typed model + invocation wrapper over the native
// `startAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke` and
// `disposeAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke`
// MethodChannel routes. Combines the existing Dart-to-native layout-map
// bridge pattern (`vg_multicam_compositor_smoke.dart`) with the existing
// GLES/OES spatial render route (`vg_multicam_spatial_gles_oes_render_smoke.dart`):
// this Dart layer sends only primitive descriptor fields (layoutMode,
// pipAnchor, pipCenterX, pipCenterY, pipWidthFraction, pipAspectRatio,
// pipMarginFraction, splitDirection, splitRatio) -- deliberately never
// cornerRadius or opacity, which the native capability hard-sets to
// 0.0/1.0 -- and native performs all layout math
// (vanguard::compositors::ComputeMultiCamLayout()) and GLES/OES rendering.
//
// A `layoutMode: "pip"` descriptor renders the RGBA primary buffer
// (deterministic solid red) against an OES secondary buffer; a
// `layoutMode: "splitScreen"` descriptor renders an OES primary buffer
// against the RGBA secondary buffer (deterministic solid blue). OES-side
// samples assert render/readback success and the resolved
// GL_TEXTURE_EXTERNAL_OES target (0x8D65) only -- never color content,
// since the YCBCR buffers are never CPU-filled. An unrecognized descriptor
// string fails closed natively with an explicit reason before any GLES
// work begins.
//
// No Camera2, no Vulkan, no opacity, no corner radius, no YCBCR color
// claim, no recording, no export, and no product/editor UI.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_dual_camera_descriptor.dart'
    show
        VGDualCameraLayoutMode,
        VGDualCameraLayoutModeExtension,
        VGPiPAnchor,
        VGPiPAnchorExtension,
        VGSplitScreenDirection,
        VGSplitScreenDirectionExtension;

/// Typed, in-bounds Dart layout descriptor sent to the native dynamic-
/// descriptor spatial render smoke route. Deliberately carries no
/// `cornerRadius`/`opacity` fields -- the native capability hard-sets both
/// (0.0/1.0) regardless of caller input.
@immutable
class VGMultiCamDynamicDescriptorSpatialRenderInput {
  const VGMultiCamDynamicDescriptorSpatialRenderInput({
    required this.layoutMode,
    required this.pipAnchor,
    required this.pipCenterX,
    required this.pipCenterY,
    required this.pipWidthFraction,
    required this.pipAspectRatio,
    required this.pipMarginFraction,
    required this.splitDirection,
    required this.splitRatio,
  });

  /// A safe, in-bounds freeFloating PiP descriptor exercising the
  /// RGBA-primary + OES-secondary render lane.
  factory VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip({
    double centerX = 0.7,
    double centerY = 0.3,
    double widthFraction = 0.3,
    double aspectRatio = 9.0 / 16.0,
    double marginFraction = 0.05,
  }) {
    return VGMultiCamDynamicDescriptorSpatialRenderInput(
      layoutMode: VGDualCameraLayoutMode.pip,
      pipAnchor: VGPiPAnchor.freeFloating,
      pipCenterX: centerX,
      pipCenterY: centerY,
      pipWidthFraction: widthFraction,
      pipAspectRatio: aspectRatio,
      pipMarginFraction: marginFraction,
      splitDirection: VGSplitScreenDirection.topBottom,
      splitRatio: 0.5,
    );
  }

  /// A safe, in-bounds leftRight split descriptor exercising the
  /// OES-primary + RGBA-secondary render lane.
  factory VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit({
    double splitRatio = 0.4,
  }) {
    return VGMultiCamDynamicDescriptorSpatialRenderInput(
      layoutMode: VGDualCameraLayoutMode.splitScreen,
      pipAnchor: VGPiPAnchor.freeFloating,
      pipCenterX: 0.5,
      pipCenterY: 0.5,
      pipWidthFraction: 0.3,
      pipAspectRatio: 9.0 / 16.0,
      pipMarginFraction: 0.05,
      splitDirection: VGSplitScreenDirection.leftRight,
      splitRatio: splitRatio,
    );
  }

  final VGDualCameraLayoutMode layoutMode;
  final VGPiPAnchor pipAnchor;
  final double pipCenterX;
  final double pipCenterY;
  final double pipWidthFraction;
  final double pipAspectRatio;
  final double pipMarginFraction;
  final VGSplitScreenDirection splitDirection;
  final double splitRatio;

  /// Serializes to the exact primitive Dart-string map shape the native
  /// route expects. Native accepts exactly these strings: `layoutMode`
  /// pip/splitScreen; `pipAnchor`
  /// freeFloating/topLeft/topRight/bottomLeft/bottomRight; `splitDirection`
  /// topBottom/leftRight.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'layoutMode': layoutMode.value,
      'pipAnchor': pipAnchor.value,
      'pipCenterX': pipCenterX,
      'pipCenterY': pipCenterY,
      'pipWidthFraction': pipWidthFraction,
      'pipAspectRatio': pipAspectRatio,
      'pipMarginFraction': pipMarginFraction,
      'splitDirection': splitDirection.value,
      'splitRatio': splitRatio,
    };
  }
}

/// Decision produced by the native Phase 3 MultiCam dynamic-descriptor spatial render smoke harness.
enum VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision {
  /// All native descriptor-parse/layout/render/readback assertions passed.
  pass,

  /// One or more native assertions failed, including an expected fail-closed
  /// malformed/unknown descriptor lane.
  fail,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw native/Kotlin decision string to the matching enum value,
  /// falling back to [harnessException] for unrecognised/missing values.
  static VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision fromRaw(
    Object? raw,
  ) {
    if (raw is! String) {
      return VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision
          .harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fail;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision
          .harnessException;
    }
    for (final value
        in VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision
        .harnessException;
  }
}

/// Typed report returned by
/// [VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.startAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke]'s
/// completion callback, mirroring the native harness's result map.
@immutable
class VGMultiCamDynamicDescriptorSpatialRenderSmokeReport {
  const VGMultiCamDynamicDescriptorSpatialRenderSmokeReport({
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
      'native_multicam_dynamic_descriptor_spatial_gles_oes_render_readback_only_no_vulkan_no_camera_no_opacity_no_corner_radius_no_ycbcr_color_claim_no_recording_no_product';

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed lifecycle decision.
  final VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision decision;

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

  bool get rgbaADescribePass => metrics['rgbaADescribe'] == 'success';
  bool get rgbaAFillPass => metrics['rgbaAFill'] == 'success';
  bool get rgbaBDescribePass => metrics['rgbaBDescribe'] == 'success';
  bool get rgbaBFillPass => metrics['rgbaBFill'] == 'success';
  bool get ycbcrADescribePass => metrics['ycbcrADescribe'] == 'success';
  bool get ycbcrAFormatIs420888 => metrics['ycbcrAFormatIs420888'] == 'true';
  bool get ycbcrBDescribePass => metrics['ycbcrBDescribe'] == 'success';
  bool get ycbcrBFormatIs420888 => metrics['ycbcrBFormatIs420888'] == 'true';
  bool get initializePass => metrics['initialize'] == 'success';
  bool get attachPass => metrics['attach'] == 'success';
  bool get importRgbaAPass => metrics['importRgbaA'] == 'success';
  bool get importRgbaBPass => metrics['importRgbaB'] == 'success';
  bool get importYcbcrAPass => metrics['importYcbcrA'] == 'success';
  bool get importYcbcrBPass => metrics['importYcbcrB'] == 'success';

  // -- Descriptor Parse & Layout Conversion Lanes --

  /// Whether native accepted the descriptor's layoutMode/pipAnchor/
  /// splitDirection strings (fails closed for unrecognized values).
  bool get descriptorParsePass => metrics['descriptorParse'] == 'success';

  /// Resolved layout mode string ("pip"/"splitScreen"), or "" if unresolved.
  String get layoutModeResolved => metrics['layoutModeResolved'] ?? '';

  /// Resolved PiP anchor string, or "" if unresolved.
  String get anchorResolved => metrics['anchorResolved'] ?? '';

  /// Resolved split direction string, or "" if unresolved.
  String get directionResolved => metrics['directionResolved'] ?? '';

  /// Whether native's normalized-to-pixel-rect layout conversion succeeded.
  bool get layoutConvertPass => metrics['layoutConvert'] == 'success';

  int get primaryRectX => int.tryParse(metrics['primaryRectX'] ?? '') ?? 0;
  int get primaryRectY => int.tryParse(metrics['primaryRectY'] ?? '') ?? 0;
  int get primaryRectWidth => int.tryParse(metrics['primaryRectW'] ?? '') ?? 0;
  int get primaryRectHeight => int.tryParse(metrics['primaryRectH'] ?? '') ?? 0;
  int get secondaryRectX => int.tryParse(metrics['secondaryRectX'] ?? '') ?? 0;
  int get secondaryRectY => int.tryParse(metrics['secondaryRectY'] ?? '') ?? 0;
  int get secondaryRectWidth =>
      int.tryParse(metrics['secondaryRectW'] ?? '') ?? 0;
  int get secondaryRectHeight =>
      int.tryParse(metrics['secondaryRectH'] ?? '') ?? 0;

  // -- Render / Readback Lanes --

  /// Render lane mode ("pip"/"splitScreen"), or "" if not run.
  String get renderLaneMode => metrics['renderLaneMode'] ?? '';

  /// "rgba" or "oes": which texture kind was drawn as primary.
  String get primaryTextureKind => metrics['primaryTextureKind'] ?? '';

  /// "rgba" or "oes": which texture kind was drawn as secondary.
  String get secondaryTextureKind => metrics['secondaryTextureKind'] ?? '';

  /// Whether the descriptor-driven spatial composite draw call succeeded.
  bool get renderDrawPass => metrics['renderDraw'] == 'success';

  /// Whether the resolved GL texture target for the primary handle matched
  /// its expected kind (GL_TEXTURE_2D for rgba, GL_TEXTURE_EXTERNAL_OES for oes).
  bool get primaryTargetOkPass => metrics['primaryTargetOk'] == 'true';

  /// Whether the resolved GL texture target for the secondary handle matched
  /// its expected kind.
  bool get secondaryTargetOkPass => metrics['secondaryTargetOk'] == 'true';

  /// Whether the primary sample point (derived, provably outside the
  /// secondary rect) read back successfully.
  bool get primarySampleReadOkPass => metrics['primarySampleReadOk'] == 'true';

  /// Whether the secondary sample point (the computed secondary rect's own
  /// center) read back successfully.
  bool get secondarySampleReadOkPass =>
      metrics['secondarySampleReadOk'] == 'true';

  /// "primary" or "secondary": which side carries the deterministic RGBA
  /// red/blue color assertion for this render lane.
  String get deterministicColorSide => metrics['deterministicColorSide'] ?? '';

  /// Whether the deterministic RGBA side's sampled color matched the
  /// expected red (pip primary) or blue (split secondary) content.
  bool get deterministicColorOkPass =>
      metrics['deterministicColorOk'] == 'true';

  /// Whether the final draw+swap present lane succeeded.
  bool get presentLanePass => metrics['presentLane'] == 'success';

  // -- Release & Teardown Lanes --

  bool get releaseRgbaAPass => metrics['releaseRgbaA'] == 'success';
  bool get releaseRgbaBPass => metrics['releaseRgbaB'] == 'success';
  bool get releaseYcbcrAPass => metrics['releaseYcbcrA'] == 'success';
  bool get releaseYcbcrBPass => metrics['releaseYcbcrB'] == 'success';
  bool get hasRgbaAAfterReleasePass =>
      metrics['hasRgbaAAfterRelease'] == 'false';
  bool get hasRgbaBAfterReleasePass =>
      metrics['hasRgbaBAfterRelease'] == 'false';
  bool get hasYcbcrAAfterReleasePass =>
      metrics['hasYcbcrAAfterRelease'] == 'false';
  bool get hasYcbcrBAfterReleasePass =>
      metrics['hasYcbcrBAfterRelease'] == 'false';

  /// Whether the post-release invalid-handle lane correctly rejected a
  /// render attempt using already-released handles.
  bool get postReleaseLanePass =>
      metrics['postReleaseLane'] == 'rejected_as_expected';

  bool get detachPass => metrics['detach'] == 'success';
  bool get shutdownPass => metrics['shutdown'] == 'success';
  bool get idempotentShutdownPass => metrics['idempotentShutdown'] == 'success';

  /// Whether all native diagnostic lanes for a well-formed descriptor
  /// passed. Not meaningful for an intentionally malformed/unknown
  /// descriptor lane, whose expected outcome is [descriptorParsePass] ==
  /// false with [decision] == fail.
  bool get allNativeLanesPass =>
      rgbaADescribePass &&
      rgbaAFillPass &&
      rgbaBDescribePass &&
      rgbaBFillPass &&
      ycbcrADescribePass &&
      ycbcrAFormatIs420888 &&
      ycbcrBDescribePass &&
      ycbcrBFormatIs420888 &&
      initializePass &&
      attachPass &&
      importRgbaAPass &&
      importRgbaBPass &&
      importYcbcrAPass &&
      importYcbcrBPass &&
      descriptorParsePass &&
      layoutConvertPass &&
      renderDrawPass &&
      primaryTargetOkPass &&
      secondaryTargetOkPass &&
      primarySampleReadOkPass &&
      secondarySampleReadOkPass &&
      deterministicColorOkPass &&
      presentLanePass &&
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

  /// Convenience getter for whether [decision] is [VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.pass].
  bool get isPass =>
      decision == VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.pass;

  /// Convenience getter for whether [decision] is [VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fail].
  bool get isFail =>
      decision == VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fail;

  /// Convenience getter for whether [decision] is [VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision ==
      VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.harnessException;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGMultiCamDynamicDescriptorSpatialRenderSmokeReport fromMap(
    Object? raw,
  ) {
    if (raw is! Map) {
      return VGMultiCamDynamicDescriptorSpatialRenderSmokeReport(
        pass: false,
        decision: VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision
            .harnessException,
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
        ? VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fromRaw(
            raw['decision'],
          )
        : (pass
              ? VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.pass
              : VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fail);

    return VGMultiCamDynamicDescriptorSpatialRenderSmokeReport(
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
      'startAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke';
  static const String _disposeMethod =
      'disposeAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Starts the Android True-DAG Phase 3 MultiCam dynamic-descriptor spatial
  /// render smoke harness.
  ///
  /// [descriptor] is the raw primitive Dart layout descriptor map -- build
  /// it via [VGMultiCamDynamicDescriptorSpatialRenderInput.toMap] for a
  /// well-formed lane, or hand-construct a deliberately malformed/unknown
  /// map to exercise the fail-closed lane.
  ///
  /// Launches the native diagnostic dynamic-descriptor spatial render pass
  /// on a background thread and returns a record containing the allocated
  /// Flutter [textureId], [width], and [height].
  ///
  /// The full [VGMultiCamDynamicDescriptorSpatialRenderSmokeReport] is
  /// delivered asynchronously via
  /// `onAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmokeComplete`.
  ///
  /// [width] and [height] default to 128x128.
  /// [channel] may be injected for testing; defaults to `vanguard_media_engine`.
  static Future<({int textureId, int width, int height})>
  startAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke({
    required Map<String, Object?> descriptor,
    int width = 128,
    int height = 128,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final raw = await ch.invokeMethod<Object?>(_startMethod, <String, Object?>{
      'width': width,
      'height': height,
      'descriptor': descriptor,
    });
    final map = raw is Map ? raw : const <Object?, Object?>{};
    final textureId = (map['textureId'] as num?)?.toInt() ?? -1;
    final w = (map['width'] as num?)?.toInt() ?? width;
    final h = (map['height'] as num?)?.toInt() ?? height;
    return (textureId: textureId, width: w, height: h);
  }

  /// Disposes the active dynamic-descriptor spatial render smoke run for
  /// [textureId].
  ///
  /// Requests cancellation if still running and releases the Flutter
  /// SurfaceProducer. Returns `true` if `surfaceProducerReleased` was
  /// confirmed by native coordinator.
  ///
  /// [channel] may be injected for testing; defaults to `vanguard_media_engine`.
  static Future<bool>
  disposeAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke({
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
    return other is VGMultiCamDynamicDescriptorSpatialRenderSmokeReport &&
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
      'VGMultiCamDynamicDescriptorSpatialRenderSmokeReport('
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
