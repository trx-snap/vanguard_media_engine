// vg_overlay_keyframe.dart
// Vanguard Media Engine - Phase 5 (P5-OVERLAYS-KEYFRAME-INTERP)
//
// Pure Dart data model for timeline overlay keyframes and evaluated transforms.

import '../../vg_overlay_descriptor.dart';

/// Interpolation curve applied between consecutive overlay keyframes.
enum VGOverlayInterpolation {
  /// Piecewise linear interpolation.
  linear('linear'),

  /// Cubic smoothstep ease-in-out interpolation: f(t) = 3t^2 - 2t^3.
  easeInOut('easeInOut'),

  /// Cubic smoothstep interpolation (alias for easeInOut).
  smoothstep('smoothstep'),

  /// Step (hold) - holds the start keyframe transform until the next keyframe.
  hold('hold');

  const VGOverlayInterpolation(this.value);

  /// Wire format string representation.
  final String value;

  /// Resolves a wire-format or enum name string to [VGOverlayInterpolation].
  ///
  /// Throws [ArgumentError] if [value] is unrecognized.
  static VGOverlayInterpolation fromValue(String value) {
    for (final mode in VGOverlayInterpolation.values) {
      if (mode.value == value || mode.name == value) return mode;
    }
    throw ArgumentError.value(
      value,
      'value',
      'Unsupported VGOverlayInterpolation',
    );
  }

  /// Alias for [fromValue].
  static VGOverlayInterpolation fromString(String value) => fromValue(value);
}

/// A single keyframe snapshot of an overlay's spatial transform and opacity
/// at an overlay-local elapsed time.
///
/// Geometry is in absolute canvas pixels with top-left origin.
///
/// Immutable value type.
final class VGOverlayKeyframe {
  /// Overlay-local elapsed time in seconds. Must be finite and >= 0.0.
  final double timeSeconds;

  /// Horizontal position of the overlay's top-left corner in canvas pixels.
  final double translationX;

  /// Vertical position of the overlay's top-left corner in canvas pixels.
  final double translationY;

  /// Overlay width in canvas pixels. Must be finite and >= 0.0.
  final double width;

  /// Overlay height in canvas pixels. Must be finite and >= 0.0.
  final double height;

  /// Rotation in radians, clockwise-positive. Must be finite.
  final double rotation;

  /// Uniform scale factor. Must be finite and > 0.0.
  final double scale;

  /// Opacity multiplier in [0.0, 1.0]. Must be finite.
  final double opacity;

  /// Interpolation mode governing the segment from this keyframe to the next.
  final VGOverlayInterpolation interpolation;

  /// Creates an immutable overlay keyframe snapshot.
  ///
  /// Fails closed with [ArgumentError] if any numeric parameter is non-finite,
  /// if [timeSeconds], [width], or [height] are negative, if [scale] <= 0,
  /// or if [opacity] is outside [0.0, 1.0].
  VGOverlayKeyframe({
    required this.timeSeconds,
    this.translationX = 0.0,
    this.translationY = 0.0,
    this.width = 0.0,
    this.height = 0.0,
    this.rotation = 0.0,
    this.scale = 1.0,
    this.opacity = 1.0,
    this.interpolation = VGOverlayInterpolation.linear,
  }) {
    if (!timeSeconds.isFinite || timeSeconds < 0.0) {
      throw ArgumentError.value(
        timeSeconds,
        'timeSeconds',
        'timeSeconds must be finite and >= 0.0',
      );
    }
    if (!translationX.isFinite) {
      throw ArgumentError.value(
        translationX,
        'translationX',
        'translationX must be finite',
      );
    }
    if (!translationY.isFinite) {
      throw ArgumentError.value(
        translationY,
        'translationY',
        'translationY must be finite',
      );
    }
    if (!width.isFinite || width < 0.0) {
      throw ArgumentError.value(
        width,
        'width',
        'width must be finite and >= 0.0',
      );
    }
    if (!height.isFinite || height < 0.0) {
      throw ArgumentError.value(
        height,
        'height',
        'height must be finite and >= 0.0',
      );
    }
    if (!rotation.isFinite) {
      throw ArgumentError.value(
        rotation,
        'rotation',
        'rotation must be finite',
      );
    }
    if (!scale.isFinite || scale <= 0.0) {
      throw ArgumentError.value(
        scale,
        'scale',
        'scale must be finite and > 0.0',
      );
    }
    if (!opacity.isFinite || opacity < 0.0 || opacity > 1.0) {
      throw ArgumentError.value(
        opacity,
        'opacity',
        'opacity must be finite and in [0.0, 1.0]',
      );
    }
  }

  /// Returns a copy of this keyframe with the specified fields replaced.
  VGOverlayKeyframe copyWith({
    double? timeSeconds,
    double? translationX,
    double? translationY,
    double? width,
    double? height,
    double? rotation,
    double? scale,
    double? opacity,
    VGOverlayInterpolation? interpolation,
  }) {
    return VGOverlayKeyframe(
      timeSeconds: timeSeconds ?? this.timeSeconds,
      translationX: translationX ?? this.translationX,
      translationY: translationY ?? this.translationY,
      width: width ?? this.width,
      height: height ?? this.height,
      rotation: rotation ?? this.rotation,
      scale: scale ?? this.scale,
      opacity: opacity ?? this.opacity,
      interpolation: interpolation ?? this.interpolation,
    );
  }

  /// Serializes this keyframe to a JSON-compatible map.
  Map<String, Object> toMap() {
    return <String, Object>{
      'timeSeconds': timeSeconds,
      'translationX': translationX,
      'translationY': translationY,
      'width': width,
      'height': height,
      'rotation': rotation,
      'scale': scale,
      'opacity': opacity,
      'interpolation': interpolation.value,
    };
  }

  /// JSON serialization alias.
  Map<String, dynamic> toJson() => toMap();

  /// Deserializes a [VGOverlayKeyframe] from a map.
  ///
  /// Throws [ArgumentError] if required keys are missing or values are invalid.
  static VGOverlayKeyframe fromMap(Map<Object?, Object?> map) {
    final rawTime = map['timeSeconds'];
    if (rawTime is! num) {
      throw ArgumentError('timeSeconds is required and must be a number.');
    }
    final timeSeconds = rawTime.toDouble();

    final rawTX = map['translationX'];
    final double translationX = (rawTX is num) ? rawTX.toDouble() : 0.0;

    final rawTY = map['translationY'];
    final double translationY = (rawTY is num) ? rawTY.toDouble() : 0.0;

    final rawWidth = map['width'];
    final double width = (rawWidth is num) ? rawWidth.toDouble() : 0.0;

    final rawHeight = map['height'];
    final double height = (rawHeight is num) ? rawHeight.toDouble() : 0.0;

    final rawRotation = map['rotation'];
    final double rotation = (rawRotation is num) ? rawRotation.toDouble() : 0.0;

    final rawScale = map['scale'];
    final double scale = (rawScale is num) ? rawScale.toDouble() : 1.0;

    final rawOpacity = map['opacity'];
    final double opacity = (rawOpacity is num) ? rawOpacity.toDouble() : 1.0;

    final rawInterp = map['interpolation'];
    final VGOverlayInterpolation interpolation;
    if (rawInterp is String) {
      interpolation = VGOverlayInterpolation.fromValue(rawInterp);
    } else if (rawInterp == null) {
      interpolation = VGOverlayInterpolation.linear;
    } else {
      throw ArgumentError('interpolation must be a String if provided.');
    }

    return VGOverlayKeyframe(
      timeSeconds: timeSeconds,
      translationX: translationX,
      translationY: translationY,
      width: width,
      height: height,
      rotation: rotation,
      scale: scale,
      opacity: opacity,
      interpolation: interpolation,
    );
  }

  /// JSON deserialization factory.
  factory VGOverlayKeyframe.fromJson(Map<String, dynamic> json) =>
      VGOverlayKeyframe.fromMap(json);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VGOverlayKeyframe) return false;
    return other.timeSeconds == timeSeconds &&
        other.translationX == translationX &&
        other.translationY == translationY &&
        other.width == width &&
        other.height == height &&
        other.rotation == rotation &&
        other.scale == scale &&
        other.opacity == opacity &&
        other.interpolation == interpolation;
  }

  @override
  int get hashCode => Object.hash(
    timeSeconds,
    translationX,
    translationY,
    width,
    height,
    rotation,
    scale,
    opacity,
    interpolation,
  );

  @override
  String toString() {
    return 'VGOverlayKeyframe('
        't: ${timeSeconds.toStringAsFixed(3)}s, '
        'pos: (${translationX.toStringAsFixed(1)}, ${translationY.toStringAsFixed(1)}), '
        'size: ${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)}, '
        'rot: ${rotation.toStringAsFixed(3)}, '
        'scale: ${scale.toStringAsFixed(2)}, '
        'opacity: ${opacity.toStringAsFixed(2)}, '
        'interp: ${interpolation.value})';
  }
}

/// Evaluated overlay state at a specific point in time, preserving identity,
/// content metadata, draw order, and evaluated spatial transform.
///
/// Immutable value type.
final class VGOverlayEvaluatedTransform {
  /// Unique identifier of the source overlay.
  final String id;

  /// Kind of overlay element (text, emoji, sticker).
  final VGOverlayType type;

  /// Timeline start time in seconds.
  final double startTimeSeconds;

  /// Overlay duration in seconds.
  final double durationSeconds;

  /// Evaluated X position of top-left corner in canvas pixels.
  final double translationX;

  /// Evaluated Y position of top-left corner in canvas pixels.
  final double translationY;

  /// Evaluated width in canvas pixels.
  final double width;

  /// Evaluated height in canvas pixels.
  final double height;

  /// Evaluated rotation in radians, clockwise-positive.
  final double rotation;

  /// Evaluated scale factor (> 0.0).
  final double scale;

  /// Evaluated opacity in [0.0, 1.0].
  final double opacity;

  /// Draw order index. Higher values render on top.
  final int zIndex;

  /// Text content for text/emoji overlays (null for sticker overlays).
  final String? textContent;

  /// Asset path for sticker overlays (null for text/emoji overlays).
  final String? assetPath;

  /// Creates an evaluated overlay transform result.
  VGOverlayEvaluatedTransform({
    required this.id,
    required this.type,
    required this.startTimeSeconds,
    required this.durationSeconds,
    required this.translationX,
    required this.translationY,
    required this.width,
    required this.height,
    required this.rotation,
    required this.scale,
    required this.opacity,
    required this.zIndex,
    this.textContent,
    this.assetPath,
  }) {
    if (!startTimeSeconds.isFinite || startTimeSeconds < 0.0) {
      throw ArgumentError.value(
        startTimeSeconds,
        'startTimeSeconds',
        'startTimeSeconds must be finite and >= 0.0',
      );
    }
    if (!durationSeconds.isFinite || durationSeconds < 0.0) {
      throw ArgumentError.value(
        durationSeconds,
        'durationSeconds',
        'durationSeconds must be finite and >= 0.0',
      );
    }
    if (!translationX.isFinite) {
      throw ArgumentError.value(
        translationX,
        'translationX',
        'translationX must be finite',
      );
    }
    if (!translationY.isFinite) {
      throw ArgumentError.value(
        translationY,
        'translationY',
        'translationY must be finite',
      );
    }
    if (!width.isFinite || width < 0.0) {
      throw ArgumentError.value(
        width,
        'width',
        'width must be finite and >= 0.0',
      );
    }
    if (!height.isFinite || height < 0.0) {
      throw ArgumentError.value(
        height,
        'height',
        'height must be finite and >= 0.0',
      );
    }
    if (!rotation.isFinite) {
      throw ArgumentError.value(
        rotation,
        'rotation',
        'rotation must be finite',
      );
    }
    if (!scale.isFinite || scale <= 0.0) {
      throw ArgumentError.value(
        scale,
        'scale',
        'scale must be finite and > 0.0',
      );
    }
    if (!opacity.isFinite || opacity < 0.0 || opacity > 1.0) {
      throw ArgumentError.value(
        opacity,
        'opacity',
        'opacity must be finite and in [0.0, 1.0]',
      );
    }
  }

  /// Creates an evaluated transform from a static [VGOverlayDescriptor] with optional
  /// evaluated geometry overrides.
  factory VGOverlayEvaluatedTransform.fromDescriptor(
    VGOverlayDescriptor descriptor, {
    double? translationX,
    double? translationY,
    double? width,
    double? height,
    double? rotation,
    double? scale,
    double? opacity,
  }) {
    return VGOverlayEvaluatedTransform(
      id: descriptor.id,
      type: descriptor.type,
      startTimeSeconds: descriptor.startTimeSeconds,
      durationSeconds: descriptor.durationSeconds,
      translationX: translationX ?? descriptor.translationX,
      translationY: translationY ?? descriptor.translationY,
      width: width ?? descriptor.width,
      height: height ?? descriptor.height,
      rotation: rotation ?? descriptor.rotation,
      scale: scale ?? descriptor.scale,
      opacity: opacity ?? descriptor.opacity,
      zIndex: descriptor.zIndex,
      textContent: descriptor.textContent,
      assetPath: descriptor.assetPath,
    );
  }

  /// Converts this evaluated transform into a static [VGOverlayDescriptor].
  VGOverlayDescriptor toDescriptor() {
    return VGOverlayDescriptor(
      id: id,
      type: type,
      startTimeSeconds: startTimeSeconds,
      durationSeconds: durationSeconds,
      translationX: translationX,
      translationY: translationY,
      width: width,
      height: height,
      rotation: rotation,
      scale: scale,
      opacity: opacity,
      zIndex: zIndex,
      textContent: textContent,
      assetPath: assetPath,
    );
  }

  /// Returns a copy of this evaluated transform with the specified fields replaced.
  VGOverlayEvaluatedTransform copyWith({
    String? id,
    VGOverlayType? type,
    double? startTimeSeconds,
    double? durationSeconds,
    double? translationX,
    double? translationY,
    double? width,
    double? height,
    double? rotation,
    double? scale,
    double? opacity,
    int? zIndex,
    String? textContent,
    String? assetPath,
  }) {
    return VGOverlayEvaluatedTransform(
      id: id ?? this.id,
      type: type ?? this.type,
      startTimeSeconds: startTimeSeconds ?? this.startTimeSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      translationX: translationX ?? this.translationX,
      translationY: translationY ?? this.translationY,
      width: width ?? this.width,
      height: height ?? this.height,
      rotation: rotation ?? this.rotation,
      scale: scale ?? this.scale,
      opacity: opacity ?? this.opacity,
      zIndex: zIndex ?? this.zIndex,
      textContent: textContent ?? this.textContent,
      assetPath: assetPath ?? this.assetPath,
    );
  }

  /// Serializes this evaluated transform to a JSON-compatible map.
  Map<String, Object> toMap() {
    final m = <String, Object>{
      'id': id,
      'type': type.value,
      'startTimeSeconds': startTimeSeconds,
      'durationSeconds': durationSeconds,
      'translationX': translationX,
      'translationY': translationY,
      'width': width,
      'height': height,
      'rotation': rotation,
      'scale': scale,
      'opacity': opacity,
      'zIndex': zIndex,
    };
    if (textContent != null) m['textContent'] = textContent!;
    if (assetPath != null) m['assetPath'] = assetPath!;
    return m;
  }

  /// JSON serialization alias.
  Map<String, dynamic> toJson() => toMap();

  /// Deserializes a [VGOverlayEvaluatedTransform] from a map.
  static VGOverlayEvaluatedTransform fromMap(Map<Object?, Object?> map) {
    final rawId = map['id'];
    final String id = (rawId is String) ? rawId : '';

    final rawType = map['type'];
    final VGOverlayType type = (rawType is String)
        ? VGOverlayType.fromValue(rawType)
        : VGOverlayType.text;

    final rawStart = map['startTimeSeconds'];
    final double startTimeSeconds = (rawStart is num)
        ? rawStart.toDouble()
        : 0.0;

    final rawDuration = map['durationSeconds'];
    final double durationSeconds = (rawDuration is num)
        ? rawDuration.toDouble()
        : 0.0;

    final rawTX = map['translationX'];
    final double translationX = (rawTX is num) ? rawTX.toDouble() : 0.0;

    final rawTY = map['translationY'];
    final double translationY = (rawTY is num) ? rawTY.toDouble() : 0.0;

    final rawWidth = map['width'];
    final double width = (rawWidth is num) ? rawWidth.toDouble() : 0.0;

    final rawHeight = map['height'];
    final double height = (rawHeight is num) ? rawHeight.toDouble() : 0.0;

    final rawRotation = map['rotation'];
    final double rotation = (rawRotation is num) ? rawRotation.toDouble() : 0.0;

    final rawScale = map['scale'];
    final double scale = (rawScale is num) ? rawScale.toDouble() : 1.0;

    final rawOpacity = map['opacity'];
    final double opacity = (rawOpacity is num) ? rawOpacity.toDouble() : 1.0;

    final rawZIndex = map['zIndex'];
    final int zIndex = (rawZIndex is num) ? rawZIndex.toInt() : 0;

    final rawTextContent = map['textContent'];
    final String? textContent = (rawTextContent is String)
        ? rawTextContent
        : null;

    final rawAssetPath = map['assetPath'];
    final String? assetPath = (rawAssetPath is String) ? rawAssetPath : null;

    return VGOverlayEvaluatedTransform(
      id: id,
      type: type,
      startTimeSeconds: startTimeSeconds,
      durationSeconds: durationSeconds,
      translationX: translationX,
      translationY: translationY,
      width: width,
      height: height,
      rotation: rotation,
      scale: scale,
      opacity: opacity,
      zIndex: zIndex,
      textContent: textContent,
      assetPath: assetPath,
    );
  }

  /// JSON deserialization factory.
  factory VGOverlayEvaluatedTransform.fromJson(Map<String, dynamic> json) =>
      VGOverlayEvaluatedTransform.fromMap(json);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VGOverlayEvaluatedTransform) return false;
    return other.id == id &&
        other.type == type &&
        other.startTimeSeconds == startTimeSeconds &&
        other.durationSeconds == durationSeconds &&
        other.translationX == translationX &&
        other.translationY == translationY &&
        other.width == width &&
        other.height == height &&
        other.rotation == rotation &&
        other.scale == scale &&
        other.opacity == opacity &&
        other.zIndex == zIndex &&
        other.textContent == textContent &&
        other.assetPath == assetPath;
  }

  @override
  int get hashCode => Object.hash(
    id,
    type,
    startTimeSeconds,
    durationSeconds,
    translationX,
    translationY,
    width,
    height,
    rotation,
    scale,
    opacity,
    zIndex,
    textContent,
    assetPath,
  );

  @override
  String toString() {
    return 'VGOverlayEvaluatedTransform('
        'id: $id, '
        'type: ${type.value}, '
        'start: ${startTimeSeconds.toStringAsFixed(2)}s, '
        'duration: ${durationSeconds.toStringAsFixed(2)}s, '
        'pos: (${translationX.toStringAsFixed(1)}, ${translationY.toStringAsFixed(1)}), '
        'size: ${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)}, '
        'rot: ${rotation.toStringAsFixed(3)}, '
        'scale: ${scale.toStringAsFixed(2)}, '
        'opacity: ${opacity.toStringAsFixed(2)}, '
        'zIndex: $zIndex)';
  }
}

/// Convenience alias for [VGOverlayEvaluatedTransform].
typedef VGOverlayTransformResult = VGOverlayEvaluatedTransform;
