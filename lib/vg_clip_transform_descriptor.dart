// vg_clip_transform_descriptor.dart
// Vanguard Media Engine — Phase 7.11
//
// Per-clip static spatial transform and opacity descriptor.
//
// Design rules (DEC-144 / Phase 7.11):
//   - Pure Dart value type. No rendering logic, no channel calls.
//   - Describes a static (non-keyframed) 2D affine transform applied to a
//     single clip in the compositor before blending.
//   - Transform is applied by VGTimelineCompositorNode using CoreImage filters:
//       CIAffineTransform (scale / rotate / translate) + CIColorMatrix (opacity).
//   - Applied AFTER Phase 7.9 orientation normalization (no double-rotation).
//   - Applied BEFORE Phase 7.10 transition blend (each clip transformed
//     independently, then blend operates on transformed buffers).
//   - Identity optimization: when all fields are at their defaults, the native
//     compositor skips the CoreImage filter chain entirely (zero overhead).
//
// Coordinate system:
//   - translationX/Y are canvas pixels. Positive X = right. Positive Y = down
//     (Flutter/UIKit top-left origin convention).
//   - Native side negates translationY for CoreImage bottom-left conversion.
//   - rotation is in radians, clockwise-positive in user/Dart convention.
//   - Native side negates rotation for CoreGraphics counter-clockwise convention.
//   - anchorX/anchorY are normalized to the source frame dimensions [0.0, 1.0].
//     (0.5, 0.5) = frame center. Native side inverts anchorY for CoreImage.
//
// Exclusions (Phase 7.11):
//   - No keyframed transforms (VGKeyframeTrackDescriptor — Phase 7 later).
//   - No crop (deferred to Phase 8 canvas system).
//   - No fit/fill mode (VGCanvasDescriptor — Phase 8).
//   - No multi-layer overlay (VGOverlayNode — Phase 8).
//   - No Android support.
//
// Serialisation wire format (toMap / fromMap):
//   {
//     'scaleX':       double,  // default 1.0
//     'scaleY':       double,  // default 1.0
//     'translationX': double,  // default 0.0, canvas pixels
//     'translationY': double,  // default 0.0, canvas pixels
//     'rotation':     double,  // default 0.0, radians clockwise
//     'opacity':      double,  // default 1.0, range [0.0, 1.0]
//     'anchorX':      double,  // default 0.5, normalized [0.0, 1.0]
//     'anchorY':      double,  // default 0.5, normalized [0.0, 1.0]
//   }

/// A static, non-keyframed per-clip spatial transform and opacity descriptor.
///
/// [VGClipTransformDescriptor] is a pure Dart value type. It holds transform
/// metadata only. No rendering logic lives here. The native
/// `VGTimelineCompositorNode` reads this descriptor from the clip dictionary
/// and applies it using CoreImage filters (DEC-144).
///
/// All field defaults produce an **identity transform** — clips with null or
/// default transforms are not modified by the compositor (identity
/// optimisation, zero overhead).
///
/// ```dart
/// // Scale clip to 50%, move right 100px, rotate 45°, half opacity:
/// final t = VGClipTransformDescriptor(
///   scaleX: 0.5,
///   scaleY: 0.5,
///   translationX: 100.0,
///   rotation: 0.785, // ~45° in radians
///   opacity: 0.5,
/// );
/// assert(t.isIdentity == false);
/// ```
final class VGClipTransformDescriptor {
  /// Creates a static spatial transform descriptor.
  ///
  /// All parameters are optional and default to identity values.
  ///
  /// [scaleX] and [scaleY] must be > 0. Zero or negative scale is rejected
  /// to prevent invisible or flipped ambiguity (Phase 7.11 conservative policy).
  ///
  /// [opacity] must be in [0.0, 1.0]. 0.0 = fully transparent, 1.0 = opaque.
  ///
  /// [anchorX] and [anchorY] must be in [0.0, 1.0]. (0.5, 0.5) = frame center.
  ///
  /// [rotation] is in radians. Positive = clockwise in user/Dart convention.
  ///
  /// [translationX] and [translationY] are in canvas pixels. Positive X =
  /// right. Positive Y = down.
  const VGClipTransformDescriptor({
    this.scaleX = 1.0,
    this.scaleY = 1.0,
    this.translationX = 0.0,
    this.translationY = 0.0,
    this.rotation = 0.0,
    this.opacity = 1.0,
    this.anchorX = 0.5,
    this.anchorY = 0.5,
  })  : assert(scaleX > 0.0, 'scaleX must be > 0'),
        assert(scaleY > 0.0, 'scaleY must be > 0'),
        assert(opacity >= 0.0 && opacity <= 1.0,
            'opacity must be in range [0.0, 1.0]'),
        assert(anchorX >= 0.0 && anchorX <= 1.0,
            'anchorX must be in range [0.0, 1.0]'),
        assert(anchorY >= 0.0 && anchorY <= 1.0,
            'anchorY must be in range [0.0, 1.0]');

  // ── Scale ──────────────────────────────────────────────────────────────────

  /// Horizontal scale factor. 1.0 = full size. Must be > 0.
  ///
  /// Values between 0 and 1 shrink; values > 1 enlarge. Negative values
  /// are rejected (Phase 7.11 conservative policy prevents invisible/flipped
  /// clips).
  final double scaleX;

  /// Vertical scale factor. 1.0 = full size. Must be > 0.
  final double scaleY;

  // ── Translation ────────────────────────────────────────────────────────────

  /// Horizontal translation in canvas pixels. Positive = right.
  ///
  /// Applied in the Flutter/UIKit top-left coordinate system. Native side
  /// converts to CoreImage coordinates.
  final double translationX;

  /// Vertical translation in canvas pixels. Positive = down.
  ///
  /// Applied in the Flutter/UIKit top-left coordinate system (positive Y
  /// points downward). Native side negates this value for the CoreImage
  /// bottom-left coordinate system.
  final double translationY;

  // ── Rotation ───────────────────────────────────────────────────────────────

  /// Rotation in radians. Positive = clockwise in user/Dart convention.
  ///
  /// Applied around the anchor point. Native side negates this value for the
  /// CoreGraphics counter-clockwise-positive convention.
  ///
  /// Common values: π/4 ≈ 0.785 rad = 45°, π/2 ≈ 1.571 rad = 90°.
  final double rotation;

  // ── Opacity ────────────────────────────────────────────────────────────────

  /// Opacity multiplier. 0.0 = fully transparent, 1.0 = fully opaque.
  ///
  /// Applied via CIColorMatrix alpha channel multiplication. The compositor
  /// renders the transformed clip over a solid black canvas; areas with
  /// opacity < 1.0 show black (Phase 7 single-track semantics).
  final double opacity;

  // ── Anchor point ───────────────────────────────────────────────────────────

  /// Normalized horizontal anchor point. 0.0 = left edge, 1.0 = right edge.
  ///
  /// Scale and rotation are applied around this point. Default 0.5 = center.
  final double anchorX;

  /// Normalized vertical anchor point. 0.0 = top edge, 1.0 = bottom edge.
  ///
  /// Scale and rotation are applied around this point. Default 0.5 = center.
  /// Native side inverts this value for CoreImage's bottom-left coordinate system.
  final double anchorY;

  // ── Identity check ─────────────────────────────────────────────────────────

  /// Whether all fields are at their identity/default values.
  ///
  /// When `true`, the native compositor skips the CoreImage filter chain
  /// entirely for this clip (identity optimisation, zero overhead).
  ///
  /// Uses exact floating-point equality, which is correct for constructor
  /// default values. Values that have drifted from defaults via computation
  /// will not be detected as identity (acceptable for Phase 7.11 — values
  /// come from UI sliders or constructor defaults, not computation).
  bool get isIdentity =>
      scaleX == 1.0 &&
      scaleY == 1.0 &&
      translationX == 0.0 &&
      translationY == 0.0 &&
      rotation == 0.0 &&
      opacity == 1.0 &&
      anchorX == 0.5 &&
      anchorY == 0.5;

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Serialises this descriptor to a JSON-compatible map.
  ///
  /// All values are doubles. The map is sent over MethodChannel as part of the
  /// clip descriptor's `transform` key.
  ///
  /// Output shape:
  /// ```json
  /// {
  ///   "scaleX": 0.5,
  ///   "scaleY": 0.5,
  ///   "translationX": 100.0,
  ///   "translationY": 0.0,
  ///   "rotation": 0.785,
  ///   "opacity": 0.8,
  ///   "anchorX": 0.5,
  ///   "anchorY": 0.5
  /// }
  /// ```
  Map<String, Object?> toMap() => <String, Object?>{
        'scaleX': scaleX,
        'scaleY': scaleY,
        'translationX': translationX,
        'translationY': translationY,
        'rotation': rotation,
        'opacity': opacity,
        'anchorX': anchorX,
        'anchorY': anchorY,
      };

  /// Deserialises a [VGClipTransformDescriptor] from a map produced by [toMap].
  ///
  /// Returns `null` if any field violates validation constraints (opacity out
  /// of range, anchor out of range, or non-positive scale). Missing fields fall
  /// back to identity defaults.
  ///
  /// The [map] parameter must be typed as `Map<Object?, Object?>` to match
  /// the MethodChannel wire contract (A2: MethodChannel returns Object? keys).
  static VGClipTransformDescriptor? fromMap(Map<Object?, Object?> map) {
    final scaleX = (map['scaleX'] as num?)?.toDouble() ?? 1.0;
    final scaleY = (map['scaleY'] as num?)?.toDouble() ?? 1.0;
    final translationX = (map['translationX'] as num?)?.toDouble() ?? 0.0;
    final translationY = (map['translationY'] as num?)?.toDouble() ?? 0.0;
    final rotation = (map['rotation'] as num?)?.toDouble() ?? 0.0;
    final opacity = (map['opacity'] as num?)?.toDouble() ?? 1.0;
    final anchorX = (map['anchorX'] as num?)?.toDouble() ?? 0.5;
    final anchorY = (map['anchorY'] as num?)?.toDouble() ?? 0.5;

    // Validate constraints — match ObjC fromDictionary: validation.
    if (scaleX <= 0.0 || scaleY <= 0.0) return null;
    if (opacity < 0.0 || opacity > 1.0) return null;
    if (anchorX < 0.0 || anchorX > 1.0) return null;
    if (anchorY < 0.0 || anchorY > 1.0) return null;

    return VGClipTransformDescriptor(
      scaleX: scaleX,
      scaleY: scaleY,
      translationX: translationX,
      translationY: translationY,
      rotation: rotation,
      opacity: opacity,
      anchorX: anchorX,
      anchorY: anchorY,
    );
  }

  // ── copyWith ───────────────────────────────────────────────────────────────

  /// Returns a copy of this descriptor with the specified fields replaced.
  ///
  /// Validation asserts are enforced on the new instance.
  VGClipTransformDescriptor copyWith({
    double? scaleX,
    double? scaleY,
    double? translationX,
    double? translationY,
    double? rotation,
    double? opacity,
    double? anchorX,
    double? anchorY,
  }) {
    return VGClipTransformDescriptor(
      scaleX: scaleX ?? this.scaleX,
      scaleY: scaleY ?? this.scaleY,
      translationX: translationX ?? this.translationX,
      translationY: translationY ?? this.translationY,
      rotation: rotation ?? this.rotation,
      opacity: opacity ?? this.opacity,
      anchorX: anchorX ?? this.anchorX,
      anchorY: anchorY ?? this.anchorY,
    );
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGClipTransformDescriptor &&
          other.scaleX == scaleX &&
          other.scaleY == scaleY &&
          other.translationX == translationX &&
          other.translationY == translationY &&
          other.rotation == rotation &&
          other.opacity == opacity &&
          other.anchorX == anchorX &&
          other.anchorY == anchorY;

  @override
  int get hashCode => Object.hash(
        scaleX,
        scaleY,
        translationX,
        translationY,
        rotation,
        opacity,
        anchorX,
        anchorY,
      );

  @override
  String toString() => 'VGClipTransformDescriptor('
      'scale: ($scaleX×, $scaleY×), '
      'translate: (${translationX}px, ${translationY}px), '
      'rotation: ${rotation}rad, '
      'opacity: $opacity, '
      'anchor: ($anchorX, $anchorY))';
}
