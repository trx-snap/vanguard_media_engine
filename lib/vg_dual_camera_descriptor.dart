// vg_dual_camera_descriptor.dart
import 'package:flutter/foundation.dart';
import 'vg_clip_descriptor.dart';

enum VGDualCameraLayoutMode {
  pip,
}

enum VGPiPAnchor {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

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
      default:
        return VGPiPAnchor.bottomRight;
    }
  }
}

extension VGDualCameraLayoutModeExtension on VGDualCameraLayoutMode {
  String get value {
    switch (this) {
      case VGDualCameraLayoutMode.pip:
        return 'pip';
    }
  }

  static VGDualCameraLayoutMode fromValue(String value) {
    switch (value) {
      case 'pip':
        return VGDualCameraLayoutMode.pip;
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
  })  : assert(widthFraction >= 0.05 && widthFraction <= 0.75, 'widthFraction must be between 0.05 and 0.75'),
        assert(marginFraction >= 0.0, 'marginFraction must be >= 0.0'),
        assert(cornerRadius >= 0.0, 'cornerRadius must be >= 0.0'),
        assert(opacity >= 0.0 && opacity <= 1.0, 'opacity must be between 0.0 and 1.0');

  final VGPiPAnchor anchor;
  final double widthFraction;
  final double marginFraction;
  final double cornerRadius;
  final double opacity;

  VGPiPLayoutDescriptor copyWith({
    VGPiPAnchor? anchor,
    double? widthFraction,
    double? marginFraction,
    double? cornerRadius,
    double? opacity,
  }) {
    return VGPiPLayoutDescriptor(
      anchor: anchor ?? this.anchor,
      widthFraction: widthFraction ?? this.widthFraction,
      marginFraction: marginFraction ?? this.marginFraction,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      opacity: opacity ?? this.opacity,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'anchor': anchor.value,
      'widthFraction': widthFraction,
      'marginFraction': marginFraction,
      'cornerRadius': cornerRadius,
      'opacity': opacity,
    };
  }

  static VGPiPLayoutDescriptor? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final anchorStr = map['anchor'] as String?;
    final anchor = anchorStr != null ? VGPiPAnchorExtension.fromValue(anchorStr) : VGPiPAnchor.bottomRight;
    
    final widthFraction = (map['widthFraction'] as num?)?.toDouble() ?? 0.35;
    final marginFraction = (map['marginFraction'] as num?)?.toDouble() ?? 0.018;
    final cornerRadius = (map['cornerRadius'] as num?)?.toDouble() ?? 24.0;
    final opacity = (map['opacity'] as num?)?.toDouble() ?? 1.0;

    if (widthFraction < 0.05 || widthFraction > 0.75) return null;
    if (marginFraction < 0.0) return null;
    if (cornerRadius < 0.0) return null;
    if (opacity < 0.0 || opacity > 1.0) return null;

    return VGPiPLayoutDescriptor(
      anchor: anchor,
      widthFraction: widthFraction,
      marginFraction: marginFraction,
      cornerRadius: cornerRadius,
      opacity: opacity,
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
          opacity == other.opacity;

  @override
  int get hashCode => Object.hash(anchor, widthFraction, marginFraction, cornerRadius, opacity);
}

@immutable
class VGDualCameraDescriptor {
  VGDualCameraDescriptor({
    required this.primaryClip,
    required this.secondaryClip,
    this.layoutMode = VGDualCameraLayoutMode.pip,
    this.pipLayout = const VGPiPLayoutDescriptor(),
  }) : assert(primaryClip.id != secondaryClip.id, 'primaryClip and secondaryClip must have different IDs');

  final VGClipDescriptor primaryClip;
  final VGClipDescriptor secondaryClip;
  final VGDualCameraLayoutMode layoutMode;
  final VGPiPLayoutDescriptor pipLayout;

  VGDualCameraDescriptor copyWith({
    VGClipDescriptor? primaryClip,
    VGClipDescriptor? secondaryClip,
    VGDualCameraLayoutMode? layoutMode,
    VGPiPLayoutDescriptor? pipLayout,
  }) {
    return VGDualCameraDescriptor(
      primaryClip: primaryClip ?? this.primaryClip,
      secondaryClip: secondaryClip ?? this.secondaryClip,
      layoutMode: layoutMode ?? this.layoutMode,
      pipLayout: pipLayout ?? this.pipLayout,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'primaryClip': primaryClip.toMap(),
      'secondaryClip': secondaryClip.toMap(),
      'layoutMode': layoutMode.value,
      'pipLayout': pipLayout.toMap(),
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
    final layoutMode = layoutModeStr != null ? VGDualCameraLayoutModeExtension.fromValue(layoutModeStr) : VGDualCameraLayoutMode.pip;
    
    final pipLayoutMap = map['pipLayout'] as Map<Object?, Object?>?;
    final pipLayout = VGPiPLayoutDescriptor.fromMap(pipLayoutMap) ?? const VGPiPLayoutDescriptor();

    return VGDualCameraDescriptor(
      primaryClip: primaryClip,
      secondaryClip: secondaryClip,
      layoutMode: layoutMode,
      pipLayout: pipLayout,
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
          pipLayout == other.pipLayout;

  @override
  int get hashCode => Object.hash(primaryClip, secondaryClip, layoutMode, pipLayout);
}
