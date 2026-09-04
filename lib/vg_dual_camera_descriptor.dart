// vg_dual_camera_descriptor.dart
// Phase 7.x-Q1 addition: toTimelineMap() and fromTimelineMap(_:primaryClip:)
// for production VGClipDescriptor wire integration.
import 'package:flutter/foundation.dart';
import 'vg_clip_descriptor.dart';

enum VGDualCameraLayoutMode { pip, splitScreen }

enum VGPiPAnchor { topLeft, topRight, bottomLeft, bottomRight, freeFloating }

enum VGSplitScreenDirection { topBottom, leftRight }

extension VGPiPAnchorExtension on VGPiPAnchor {
  String get value {
    switch (this) {
      case VGPiPAnchor.topLeft:
        return 'topLeft';
      case VGPiPAnchor.topRight:
        return 'topRight';
      case VGPiPAnchor.bottomLeft:
        return 'bottomLeft';
      case VGPiPAnchor.bottomRight:
        return 'bottomRight';
      case VGPiPAnchor.freeFloating:
        return 'freeFloating';
    }
  }

  static VGPiPAnchor fromValue(String value) {
    switch (value) {
      case 'topLeft':
        return VGPiPAnchor.topLeft;
      case 'topRight':
        return VGPiPAnchor.topRight;
      case 'bottomLeft':
        return VGPiPAnchor.bottomLeft;
      case 'bottomRight':
        return VGPiPAnchor.bottomRight;
      case 'freeFloating':
        return VGPiPAnchor.freeFloating;
      default:
        return VGPiPAnchor.bottomRight;
    }
  }
}

extension VGSplitScreenDirectionExtension on VGSplitScreenDirection {
  String get value {
    switch (this) {
      case VGSplitScreenDirection.topBottom:
        return 'topBottom';
      case VGSplitScreenDirection.leftRight:
        return 'leftRight';
    }
  }

  static VGSplitScreenDirection fromValue(String value) {
    switch (value) {
      case 'topBottom':
        return VGSplitScreenDirection.topBottom;
      case 'leftRight':
        return VGSplitScreenDirection.leftRight;
      default:
        return VGSplitScreenDirection.topBottom;
    }
  }
}

extension VGDualCameraLayoutModeExtension on VGDualCameraLayoutMode {
  String get value {
    switch (this) {
      case VGDualCameraLayoutMode.pip:
        return 'pip';
      case VGDualCameraLayoutMode.splitScreen:
        return 'splitScreen';
    }
  }

  static VGDualCameraLayoutMode fromValue(String value) {
    switch (value) {
      case 'pip':
        return VGDualCameraLayoutMode.pip;
      case 'splitScreen':
        return VGDualCameraLayoutMode.splitScreen;
      default:
        return VGDualCameraLayoutMode.pip;
    }
  }
}

@immutable
class VGPiPLayoutDescriptor {
  const VGPiPLayoutDescriptor({
    this.anchor = VGPiPAnchor.bottomRight,
    this.widthFraction = 0.35,
    this.marginFraction = 0.018,
    this.cornerRadius = 24.0,
    this.opacity = 1.0,
    this.centerX = 0.5,
    this.centerY = 0.5,
    this.aspectRatio = 9.0 / 16.0,
  }) : assert(
         widthFraction >= 0.05 && widthFraction <= 0.75,
         'widthFraction must be between 0.05 and 0.75',
       ),
       assert(
         marginFraction >= 0.0 && marginFraction < double.infinity,
         'marginFraction must be >= 0.0',
       ),
       assert(
         cornerRadius >= 0.0 && cornerRadius < double.infinity,
         'cornerRadius must be >= 0.0',
       ),
       assert(
         opacity >= 0.0 && opacity <= 1.0,
         'opacity must be between 0.0 and 1.0',
       ),
       assert(
         centerX >= 0.0 && centerX <= 1.0,
         'centerX must be between 0.0 and 1.0',
       ),
       assert(
         centerY >= 0.0 && centerY <= 1.0,
         'centerY must be between 0.0 and 1.0',
       ),
       assert(
         aspectRatio > 0.0 && aspectRatio < double.infinity,
         'aspectRatio must be finite and > 0.0',
       );

  final VGPiPAnchor anchor;
  final double widthFraction;
  final double marginFraction;
  final double cornerRadius;
  final double opacity;
  final double centerX;
  final double centerY;
  final double aspectRatio;

  VGPiPLayoutDescriptor copyWith({
    VGPiPAnchor? anchor,
    double? widthFraction,
    double? marginFraction,
    double? cornerRadius,
    double? opacity,
    double? centerX,
    double? centerY,
    double? aspectRatio,
  }) {
    return VGPiPLayoutDescriptor(
      anchor: anchor ?? this.anchor,
      widthFraction: widthFraction ?? this.widthFraction,
      marginFraction: marginFraction ?? this.marginFraction,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      opacity: opacity ?? this.opacity,
      centerX: centerX ?? this.centerX,
      centerY: centerY ?? this.centerY,
      aspectRatio: aspectRatio ?? this.aspectRatio,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'anchor': anchor.value,
      'widthFraction': widthFraction,
      'marginFraction': marginFraction,
      'cornerRadius': cornerRadius,
      'opacity': opacity,
      'centerX': centerX,
      'centerY': centerY,
      'aspectRatio': aspectRatio,
    };
  }

  static VGPiPLayoutDescriptor? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final anchorRaw = map['anchor'];
    final anchor = anchorRaw is String
        ? VGPiPAnchorExtension.fromValue(anchorRaw)
        : VGPiPAnchor.bottomRight;

    final widthFractionRaw = map['widthFraction'];
    if (widthFractionRaw != null && widthFractionRaw is! num) return null;
    final widthFraction = (widthFractionRaw as num?)?.toDouble() ?? 0.35;

    final marginFractionRaw = map['marginFraction'];
    if (marginFractionRaw != null && marginFractionRaw is! num) return null;
    final marginFraction = (marginFractionRaw as num?)?.toDouble() ?? 0.018;

    final cornerRadiusRaw = map['cornerRadius'];
    if (cornerRadiusRaw != null && cornerRadiusRaw is! num) return null;
    final cornerRadius = (cornerRadiusRaw as num?)?.toDouble() ?? 24.0;

    final opacityRaw = map['opacity'];
    if (opacityRaw != null && opacityRaw is! num) return null;
    final opacity = (opacityRaw as num?)?.toDouble() ?? 1.0;

    final centerXRaw = map['centerX'];
    if (centerXRaw != null && centerXRaw is! num) return null;
    final centerX = (centerXRaw as num?)?.toDouble() ?? 0.5;

    final centerYRaw = map['centerY'];
    if (centerYRaw != null && centerYRaw is! num) return null;
    final centerY = (centerYRaw as num?)?.toDouble() ?? 0.5;

    final aspectRatioRaw = map['aspectRatio'];
    if (aspectRatioRaw != null && aspectRatioRaw is! num) return null;
    final aspectRatio = (aspectRatioRaw as num?)?.toDouble() ?? (9.0 / 16.0);

    if (!widthFraction.isFinite ||
        widthFraction < 0.05 ||
        widthFraction > 0.75) {
      return null;
    }
    if (!marginFraction.isFinite || marginFraction < 0.0) return null;
    if (!cornerRadius.isFinite || cornerRadius < 0.0) return null;
    if (!opacity.isFinite || opacity < 0.0 || opacity > 1.0) return null;
    if (!centerX.isFinite || centerX < 0.0 || centerX > 1.0) return null;
    if (!centerY.isFinite || centerY < 0.0 || centerY > 1.0) return null;
    if (!aspectRatio.isFinite || aspectRatio <= 0.0) return null;

    return VGPiPLayoutDescriptor(
      anchor: anchor,
      widthFraction: widthFraction,
      marginFraction: marginFraction,
      cornerRadius: cornerRadius,
      opacity: opacity,
      centerX: centerX,
      centerY: centerY,
      aspectRatio: aspectRatio,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGPiPLayoutDescriptor &&
          runtimeType == other.runtimeType &&
          anchor == other.anchor &&
          widthFraction == other.widthFraction &&
          marginFraction == other.marginFraction &&
          cornerRadius == other.cornerRadius &&
          opacity == other.opacity &&
          centerX == other.centerX &&
          centerY == other.centerY &&
          aspectRatio == other.aspectRatio;

  @override
  int get hashCode => Object.hash(
    anchor,
    widthFraction,
    marginFraction,
    cornerRadius,
    opacity,
    centerX,
    centerY,
    aspectRatio,
  );
}

// ─── VGSplitScreenLayoutDescriptor ──────────────────────────────────────────
/// Configuration for the split-screen layout mode.
///
/// Phase 7.x-K: vertical portrait split — primary on top, secondary on bottom.
/// P3-MULTICAM-NODE: directional split - [direction] selects top/bottom or left/right.
/// [splitRatio] controls what fraction of the canvas height/width is allocated to
/// the primary video. Valid range: 0.2-0.8. Default: 0.5.
@immutable
class VGSplitScreenLayoutDescriptor {
  const VGSplitScreenLayoutDescriptor({
    this.splitRatio = 0.5,
    this.direction = VGSplitScreenDirection.topBottom,
  }) : assert(
         splitRatio >= 0.2 && splitRatio <= 0.8,
         'splitRatio must be between 0.2 and 0.8',
       );

  final double splitRatio;
  final VGSplitScreenDirection direction;

  VGSplitScreenLayoutDescriptor copyWith({
    double? splitRatio,
    VGSplitScreenDirection? direction,
  }) {
    return VGSplitScreenLayoutDescriptor(
      splitRatio: splitRatio ?? this.splitRatio,
      direction: direction ?? this.direction,
    );
  }

  Map<String, Object?> toMap() {
    return {'splitRatio': splitRatio, 'direction': direction.value};
  }

  static VGSplitScreenLayoutDescriptor? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final splitRatioRaw = map['splitRatio'];
    if (splitRatioRaw != null && splitRatioRaw is! num) return null;
    final ratio = (splitRatioRaw as num?)?.toDouble() ?? 0.5;
    if (!ratio.isFinite || ratio < 0.2 || ratio > 0.8) return null;

    final directionRaw = map['direction'];
    final direction = directionRaw is String
        ? VGSplitScreenDirectionExtension.fromValue(directionRaw)
        : VGSplitScreenDirection.topBottom;

    return VGSplitScreenLayoutDescriptor(
      splitRatio: ratio,
      direction: direction,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGSplitScreenLayoutDescriptor &&
          runtimeType == other.runtimeType &&
          splitRatio == other.splitRatio &&
          direction == other.direction;

  @override
  int get hashCode => Object.hash(splitRatio, direction);
}

@immutable
class VGDualCameraDescriptor {
  VGDualCameraDescriptor({
    required this.primaryClip,
    required this.secondaryClip,
    this.layoutMode = VGDualCameraLayoutMode.pip,
    this.pipLayout = const VGPiPLayoutDescriptor(),
    this.splitLayout = const VGSplitScreenLayoutDescriptor(),
  }) : assert(
         primaryClip.id != secondaryClip.id,
         'primaryClip and secondaryClip must have different IDs',
       );

  final VGClipDescriptor primaryClip;
  final VGClipDescriptor secondaryClip;
  final VGDualCameraLayoutMode layoutMode;
  final VGPiPLayoutDescriptor pipLayout;
  // Phase 7.x-K: split-screen layout configuration.
  final VGSplitScreenLayoutDescriptor splitLayout;

  VGDualCameraDescriptor copyWith({
    VGClipDescriptor? primaryClip,
    VGClipDescriptor? secondaryClip,
    VGDualCameraLayoutMode? layoutMode,
    VGPiPLayoutDescriptor? pipLayout,
    VGSplitScreenLayoutDescriptor? splitLayout,
  }) {
    return VGDualCameraDescriptor(
      primaryClip: primaryClip ?? this.primaryClip,
      secondaryClip: secondaryClip ?? this.secondaryClip,
      layoutMode: layoutMode ?? this.layoutMode,
      pipLayout: pipLayout ?? this.pipLayout,
      splitLayout: splitLayout ?? this.splitLayout,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'primaryClip': primaryClip.toMap(),
      'secondaryClip': secondaryClip.toMap(),
      'layoutMode': layoutMode.value,
      'pipLayout': pipLayout.toMap(),
      'splitLayout': splitLayout.toMap(),
    };
  }

  /// Produces the production timeline wire payload for [VGClipDescriptor.toMap].
  ///
  /// **Phase 7.x-Q1** — This secondary-only map is embedded under the
  /// 'dualCamera' key in the enclosing [VGClipDescriptor]'s map.
  ///
  /// Differs from [toMap] in one critical way:
  /// - `primaryClip` is **omitted**. The enclosing [VGClipDescriptor] IS
  ///   the primary clip; duplicating it would create field drift risk and
  ///   unnecessary payload bloat.
  ///
  /// [VGTimelineCompositorNode] (native) parses this map from the clip dict
  /// under the 'dualCamera' key. It reads `secondaryClip`, `layoutMode`,
  /// `pipLayout`, and `splitLayout`. It does not expect `primaryClip`.
  Map<String, Object?> toTimelineMap() {
    return {
      'secondaryClip': secondaryClip.toMap(),
      'layoutMode': layoutMode.value,
      'pipLayout': pipLayout.toMap(),
      'splitLayout': splitLayout.toMap(),
    };
  }

  static VGDualCameraDescriptor? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;

    final primaryMap = map['primaryClip'] as Map<Object?, Object?>?;
    final secondaryMap = map['secondaryClip'] as Map<Object?, Object?>?;
    if (primaryMap == null || secondaryMap == null) return null;

    final primaryClip = VGClipDescriptor.fromMap(primaryMap);
    final secondaryClip = VGClipDescriptor.fromMap(secondaryMap);
    if (primaryClip == null || secondaryClip == null) return null;
    if (primaryClip.id == secondaryClip.id) return null;

    final layoutModeStr = map['layoutMode'] as String?;
    final layoutMode = layoutModeStr != null
        ? VGDualCameraLayoutModeExtension.fromValue(layoutModeStr)
        : VGDualCameraLayoutMode.pip;

    final pipLayoutMap = map['pipLayout'] as Map<Object?, Object?>?;
    final pipLayout =
        VGPiPLayoutDescriptor.fromMap(pipLayoutMap) ??
        const VGPiPLayoutDescriptor();

    // Phase 7.x-K: parse splitLayout; fallback to default.
    final splitLayoutMap = map['splitLayout'] as Map<Object?, Object?>?;
    final splitLayout =
        VGSplitScreenLayoutDescriptor.fromMap(splitLayoutMap) ??
        const VGSplitScreenLayoutDescriptor();

    return VGDualCameraDescriptor(
      primaryClip: primaryClip,
      secondaryClip: secondaryClip,
      layoutMode: layoutMode,
      pipLayout: pipLayout,
      splitLayout: splitLayout,
    );
  }

  /// Reconstructs a [VGDualCameraDescriptor] from a secondary-only timeline map.
  ///
  /// **Phase 7.x-Q1** — The [map] is produced by [toTimelineMap] and does
  /// NOT contain a 'primaryClip' key. The caller must supply [primaryClip]
  /// (the enclosing [VGClipDescriptor]).
  ///
  /// Returns null if [map] is null, missing 'secondaryClip', or contains an
  /// invalid secondary clip. Returns null if [primaryClip].id equals the
  /// deserialized secondaryClip.id (same-ID guard).
  static VGDualCameraDescriptor? fromTimelineMap(
    Map<Object?, Object?> map, {
    required VGClipDescriptor primaryClip,
  }) {
    final secondaryMap = map['secondaryClip'] as Map<Object?, Object?>?;
    if (secondaryMap == null) return null;

    final secondaryClip = VGClipDescriptor.fromMap(secondaryMap);
    if (secondaryClip == null) return null;
    if (primaryClip.id == secondaryClip.id) return null;

    final layoutModeStr = map['layoutMode'] as String?;
    final layoutMode = layoutModeStr != null
        ? VGDualCameraLayoutModeExtension.fromValue(layoutModeStr)
        : VGDualCameraLayoutMode.pip;

    final pipLayoutMap = map['pipLayout'] as Map<Object?, Object?>?;
    final pipLayout =
        VGPiPLayoutDescriptor.fromMap(pipLayoutMap) ??
        const VGPiPLayoutDescriptor();

    final splitLayoutMap = map['splitLayout'] as Map<Object?, Object?>?;
    final splitLayout =
        VGSplitScreenLayoutDescriptor.fromMap(splitLayoutMap) ??
        const VGSplitScreenLayoutDescriptor();

    return VGDualCameraDescriptor(
      primaryClip: primaryClip,
      secondaryClip: secondaryClip,
      layoutMode: layoutMode,
      pipLayout: pipLayout,
      splitLayout: splitLayout,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDualCameraDescriptor &&
          runtimeType == other.runtimeType &&
          primaryClip == other.primaryClip &&
          secondaryClip == other.secondaryClip &&
          layoutMode == other.layoutMode &&
          pipLayout == other.pipLayout &&
          splitLayout == other.splitLayout;

  @override
  int get hashCode => Object.hash(
    primaryClip,
    secondaryClip,
    layoutMode,
    pipLayout,
    splitLayout,
  );
}
