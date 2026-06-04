// vg_transform_keyframe_descriptor.dart
// Vanguard Media Engine — Phase 7.23
//
// Timeline keyframe foundation: descriptor-only, pure Dart interpolation math.
//
// Design rules (Phase 7.23 / DEC-167):
//   - These are pure Dart value types describing keyframed transform/opacity
//     metadata for a single clip.
//   - They do NOT implement any runtime rendering, compositor integration,
//     native parsing, or export behavior changes.
//   - The native compositor (VGTimelineCompositorNode) ignores transformTrack
//     in Phase 7.23. Runtime integration is Phase 7.23B.
//   - Android implementation is out of scope.
//   - Phase 8 UI is out of scope.
//
// Timebase:
//   - keyframe.timeUs is clip-local elapsed timeline time in microseconds.
//   - 0 = the moment the clip first appears on the timeline (post-trim, post-layout).
//   - This is independent of source-asset PTS, timeRemap internal mapping,
//     and global timeline position. The compositor maps global T to
//     elapsedTimeline = T - clip.startTimeSeconds; keyframes evaluate on
//     elapsedTimeline * 1e6 = timeUs.
//
// Precedence rule (DEC-167):
//   - When VGClipDescriptor.transformTrack is present, runtime rendering will
//     use it instead of VGClipDescriptor.transform (static transform).
//   - The two descriptors are NOT composed together.
//   - Static transform remains stored as a fallback if transformTrack is absent
//     or later cleared.
//   - Runtime integration is Phase 7.23B.
//
// Anchor policy:
//   - Anchor (anchorX/anchorY) is track-level, NOT per-keyframe.
//   - A single anchor applies uniformly across all keyframes in the track.
//   - Animating the anchor point simultaneously with scale/rotation produces
//     unintuitive double-pivot behavior; Phase 7.23 does not support it.
//
// Interpolation:
//   - VGKeyframeInterpolation.linear: piecewise linear interpolation.
//     Scale is linearly interpolated (always > 0 between valid keyframes;
//     clamped to a small positive floor defensively). Opacity is clamped to
//     [0.0, 1.0] defensively. Rotation uses direct lerp (no wraparound/slerp).
//   - VGKeyframeInterpolation.hold: previous keyframe value held until
//     the next keyframe time is reached.
//   - Before first keyframe: clamp to first keyframe.
//   - After last keyframe: clamp to last keyframe.
//
// Serialisation:
//   VGTransformKeyframeDescriptor.toMap() produces:
//   {
//     'timeUs':       int,     // >= 0, clip-local elapsed µs
//     'scaleX':       double,  // > 0
//     'scaleY':       double,  // > 0
//     'translationX': double,  // canvas pixels, positive = right
//     'translationY': double,  // canvas pixels, positive = down
//     'rotation':     double,  // radians, clockwise-positive (user convention)
//     'opacity':      double,  // [0.0, 1.0]
//   }
//
//   VGTransformTrackDescriptor.toMap() produces:
//   {
//     'interpolation': String,   // 'linear' | 'hold'
//     'anchorX':       double,   // [0.0, 1.0], default 0.5
//     'anchorY':       double,   // [0.0, 1.0], default 0.5
//     'keyframes':     List<Map>, // ordered by timeUs ascending, no duplicates
//   }
//
// References:
//   - DEC-167 (Phase 7.23 keyframe foundation decision — TBD in decision_log.md)
//   - DEC-V2-026 (Phase 7 non-destructive descriptor contract)
//   - VGClipTransformDescriptor (the static transform value type this reuses for output)

import 'vg_clip_transform_descriptor.dart';

// ── VGKeyframeInterpolation ──────────────────────────────────────────────────

/// Interpolation mode for a [VGTransformTrackDescriptor].
///
/// Controls how the compositor evaluates transform values between defined
/// keyframe timestamps.
///
/// Wire values (in toMap / fromMap) are lowercase strings matching this enum's
/// [value] field. Unknown wire strings resolve to [linear] (safe default).
enum VGKeyframeInterpolation {
  /// Piecewise linear interpolation between consecutive keyframes.
  ///
  /// Each property (scaleX, scaleY, translationX, translationY, rotation,
  /// opacity) is interpolated independently using the standard lerp formula:
  ///   value = a + (b - a) * t
  /// where t = (timeUs - keyframe[i].timeUs) / (keyframe[i+1].timeUs - keyframe[i].timeUs).
  ///
  /// Scale values are defensively clamped to > 0. Opacity is defensively
  /// clamped to [0.0, 1.0]. Rotation uses direct linear interpolation;
  /// no shortest-path slerp in Phase 7.23.
  linear('linear'),

  /// Hold: previous keyframe value is returned unchanged until the next
  /// keyframe's timeUs is reached (step function).
  ///
  /// Useful for jump-cut style transform changes with no smooth transition.
  hold('hold');

  const VGKeyframeInterpolation(this.value);

  /// The wire-format string sent over MethodChannel and in toMap().
  final String value;

  /// Resolves a wire-format string to the corresponding interpolation mode.
  ///
  /// Returns [VGKeyframeInterpolation.linear] for unrecognised strings
  /// (safe conservative default).
  static VGKeyframeInterpolation fromValue(String value) {
    for (final mode in VGKeyframeInterpolation.values) {
      if (mode.value == value) return mode;
    }
    return VGKeyframeInterpolation.linear;
  }
}

// ── VGTransformKeyframeDescriptor ────────────────────────────────────────────

/// A single keyframe snapshot of a clip's transform and opacity at a given
/// clip-local elapsed time.
///
/// Keyframes are collected into a [VGTransformTrackDescriptor], which evaluates
/// them at any requested timeUs using its declared [VGKeyframeInterpolation]
/// mode.
///
/// **Phase 7.23 / DEC-167**: Descriptor and interpolation math only.
/// No runtime rendering is implemented. The native compositor ignores
/// [VGClipDescriptor.transformTrack] until Phase 7.23B.
///
/// **Anchor policy**: Anchor is track-level, not per-keyframe. Each keyframe
/// carries the 6 animatable properties only.
///
/// Wire format produced by [toMap]:
/// ```json
/// {
///   "timeUs":       0,
///   "scaleX":       1.0,
///   "scaleY":       1.0,
///   "translationX": 0.0,
///   "translationY": 0.0,
///   "rotation":     0.0,
///   "opacity":      1.0
/// }
/// ```
final class VGTransformKeyframeDescriptor {
  /// Creates a transform keyframe descriptor.
  ///
  /// [timeUs] is the clip-local elapsed timeline time in microseconds at which
  /// this keyframe applies. Must be >= 0.
  ///
  /// [scaleX] and [scaleY] are horizontal and vertical scale factors. Must be
  /// > 0. Use 1.0 for no scaling.
  ///
  /// [translationX] and [translationY] are canvas pixels. Positive X = right,
  /// positive Y = down (Flutter/UIKit top-left origin convention).
  ///
  /// [rotation] is in radians, clockwise-positive in user/Dart convention.
  ///
  /// [opacity] must be in [0.0, 1.0]. 0.0 = fully transparent, 1.0 = opaque.
  const VGTransformKeyframeDescriptor({
    required this.timeUs,
    this.scaleX = 1.0,
    this.scaleY = 1.0,
    this.translationX = 0.0,
    this.translationY = 0.0,
    this.rotation = 0.0,
    this.opacity = 1.0,
  })  : assert(timeUs >= 0, 'timeUs must be >= 0'),
        assert(scaleX > 0.0, 'scaleX must be > 0'),
        assert(scaleY > 0.0, 'scaleY must be > 0'),
        assert(
          opacity >= 0.0 && opacity <= 1.0,
          'opacity must be in range [0.0, 1.0]',
        );

  // ── Timebase ───────────────────────────────────────────────────────────────

  /// Clip-local elapsed timeline time at which this keyframe applies.
  ///
  /// Unit: microseconds (µs).
  ///
  /// 0 = the clip's first frame on the timeline (post-trim, post-layout).
  /// This is independent of source-asset PTS, timeRemap, and global timeline
  /// position.
  final int timeUs;

  // ── Animatable properties ──────────────────────────────────────────────────

  /// Horizontal scale factor. 1.0 = full size. Must be > 0.
  final double scaleX;

  /// Vertical scale factor. 1.0 = full size. Must be > 0.
  final double scaleY;

  /// Horizontal translation in canvas pixels. Positive = right.
  final double translationX;

  /// Vertical translation in canvas pixels. Positive = down.
  final double translationY;

  /// Rotation in radians. Positive = clockwise in user/Dart convention.
  final double rotation;

  /// Opacity multiplier. 0.0 = fully transparent, 1.0 = fully opaque.
  final double opacity;

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Serialises this keyframe to a JSON-compatible map.
  ///
  /// Note: anchorX/anchorY are NOT included here — they live on the track.
  Map<String, Object> toMap() => <String, Object>{
        'timeUs': timeUs,
        'scaleX': scaleX,
        'scaleY': scaleY,
        'translationX': translationX,
        'translationY': translationY,
        'rotation': rotation,
        'opacity': opacity,
      };

  /// Deserialises a [VGTransformKeyframeDescriptor] from a map produced by [toMap].
  ///
  /// Returns null if:
  ///   - 'timeUs' is missing or negative.
  ///   - 'scaleX' or 'scaleY' is <= 0.
  ///   - 'opacity' is outside [0.0, 1.0].
  ///   - Any required numeric field is not a valid finite number.
  static VGTransformKeyframeDescriptor? fromMap(Map<Object?, Object?> map) {
    final rawTimeUs = map['timeUs'];
    if (rawTimeUs is! int) {
      // Accept int only for timeUs — double would suggest wrong timebase.
      // If wire sends a num, coerce conservatively.
      if (rawTimeUs is num) {
        final intVal = rawTimeUs.toInt();
        if (intVal < 0) return null;
        return _fromMapWithTimeUs(intVal, map);
      }
      return null;
    }
    if (rawTimeUs < 0) return null;
    return _fromMapWithTimeUs(rawTimeUs, map);
  }

  static VGTransformKeyframeDescriptor? _fromMapWithTimeUs(
    int timeUs,
    Map<Object?, Object?> map,
  ) {
    final scaleX = (map['scaleX'] as num?)?.toDouble() ?? 1.0;
    final scaleY = (map['scaleY'] as num?)?.toDouble() ?? 1.0;
    final translationX = (map['translationX'] as num?)?.toDouble() ?? 0.0;
    final translationY = (map['translationY'] as num?)?.toDouble() ?? 0.0;
    final rotation = (map['rotation'] as num?)?.toDouble() ?? 0.0;
    final opacity = (map['opacity'] as num?)?.toDouble() ?? 1.0;

    // Validate.
    if (!scaleX.isFinite || scaleX <= 0.0) return null;
    if (!scaleY.isFinite || scaleY <= 0.0) return null;
    if (!translationX.isFinite) return null;
    if (!translationY.isFinite) return null;
    if (!rotation.isFinite) return null;
    if (!opacity.isFinite || opacity < 0.0 || opacity > 1.0) return null;

    return VGTransformKeyframeDescriptor(
      timeUs: timeUs,
      scaleX: scaleX,
      scaleY: scaleY,
      translationX: translationX,
      translationY: translationY,
      rotation: rotation,
      opacity: opacity,
    );
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGTransformKeyframeDescriptor &&
          other.timeUs == timeUs &&
          other.scaleX == scaleX &&
          other.scaleY == scaleY &&
          other.translationX == translationX &&
          other.translationY == translationY &&
          other.rotation == rotation &&
          other.opacity == opacity;

  @override
  int get hashCode => Object.hash(
        timeUs,
        scaleX,
        scaleY,
        translationX,
        translationY,
        rotation,
        opacity,
      );

  @override
  String toString() => 'VGTransformKeyframeDescriptor('
      'timeUs: $timeUs, '
      'scale: ($scaleX×, $scaleY×), '
      'translate: (${translationX}px, ${translationY}px), '
      'rotation: ${rotation}rad, '
      'opacity: $opacity)';
}

// ── VGTransformTrackDescriptor ────────────────────────────────────────────────

/// An ordered collection of transform keyframes with a declared interpolation
/// mode, plus a static track-level anchor point.
///
/// Evaluates the effective [VGClipTransformDescriptor] at any clip-local
/// elapsed time via [interpolatedTransformAt].
///
/// **Phase 7.23 / DEC-167**: Descriptor and interpolation math only.
/// Runtime compositor integration is Phase 7.23B.
///
/// **Keyframe ordering**: Keyframes MUST be sorted by [VGTransformKeyframeDescriptor.timeUs]
/// in ascending order. Duplicate timeUs values are invalid.
///
/// **Anchor**: [anchorX]/[anchorY] are track-level. They are applied uniformly
/// to all keyframes and are included in every [VGClipTransformDescriptor]
/// returned by [interpolatedTransformAt].
///
/// **Precedence** (DEC-167): When [VGClipDescriptor.transformTrack] is non-null,
/// runtime rendering uses it instead of [VGClipDescriptor.transform] (static).
/// The two are NOT composed together.
///
/// Wire format produced by [toMap]:
/// ```json
/// {
///   "interpolation": "linear",
///   "anchorX": 0.5,
///   "anchorY": 0.5,
///   "keyframes": [
///     { "timeUs": 0, "scaleX": 1.0, ... },
///     { "timeUs": 500000, "scaleX": 0.5, ... }
///   ]
/// }
/// ```
final class VGTransformTrackDescriptor {
  /// Creates a transform track descriptor.
  ///
  /// [keyframes] must not be empty. Keyframes must be sorted by
  /// [VGTransformKeyframeDescriptor.timeUs] in ascending order.
  /// Duplicate timeUs values are invalid.
  ///
  /// [interpolation] controls how values are computed between keyframes.
  /// Defaults to [VGKeyframeInterpolation.linear].
  ///
  /// [anchorX] and [anchorY] are the track-level pivot point for scale and
  /// rotation. Must be in [0.0, 1.0]. Default 0.5 = frame center.
  VGTransformTrackDescriptor({
    required List<VGTransformKeyframeDescriptor> keyframes,
    this.interpolation = VGKeyframeInterpolation.linear,
    this.anchorX = 0.5,
    this.anchorY = 0.5,
  })  : assert(keyframes.isNotEmpty, 'keyframes must not be empty'),
        assert(
          _validateKeyframes(keyframes),
          'keyframes must be sorted by timeUs (ascending) with no duplicate values',
        ),
        assert(anchorX >= 0.0 && anchorX <= 1.0,
            'anchorX must be in range [0.0, 1.0]'),
        assert(anchorY >= 0.0 && anchorY <= 1.0,
            'anchorY must be in range [0.0, 1.0]'),
        keyframes = List.unmodifiable(keyframes);

  /// Ordered list of keyframes. Immutable. Must not be empty.
  ///
  /// Keyframes are sorted by [VGTransformKeyframeDescriptor.timeUs] in
  /// ascending order with no duplicates.
  final List<VGTransformKeyframeDescriptor> keyframes;

  /// Interpolation mode applied between consecutive keyframes.
  final VGKeyframeInterpolation interpolation;

  /// Normalized horizontal anchor point for scale and rotation. [0.0, 1.0].
  ///
  /// 0.0 = left edge, 0.5 = center (default), 1.0 = right edge.
  final double anchorX;

  /// Normalized vertical anchor point for scale and rotation. [0.0, 1.0].
  ///
  /// 0.0 = top edge, 0.5 = center (default), 1.0 = bottom edge.
  final double anchorY;

  // ── Validation ─────────────────────────────────────────────────────────────

  /// Validates that [keyframes] are sorted by timeUs with no duplicates.
  static bool _validateKeyframes(
      List<VGTransformKeyframeDescriptor> keyframes) {
    for (var i = 1; i < keyframes.length; i++) {
      // Must be strictly increasing — duplicate timeUs is invalid.
      if (keyframes[i].timeUs <= keyframes[i - 1].timeUs) return false;
    }
    return true;
  }

  // ── Interpolation ──────────────────────────────────────────────────────────

  /// Evaluates the effective transform at [timeUs] clip-local elapsed time.
  ///
  /// Returns a [VGClipTransformDescriptor] incorporating:
  ///   - The interpolated (or held/clamped) transform properties.
  ///   - The track-level [anchorX] and [anchorY] on every returned descriptor.
  ///
  /// Boundary behaviour:
  ///   - [timeUs] before first keyframe → first keyframe values.
  ///   - [timeUs] after last keyframe → last keyframe values.
  ///   - [timeUs] exactly at a keyframe → exact keyframe values.
  ///   - Single keyframe → constant values for all valid [timeUs].
  ///
  /// [VGKeyframeInterpolation.linear]:
  ///   - Piecewise linear lerp on all 6 properties.
  ///   - scaleX/scaleY are clamped to a small positive floor (_kMinScale)
  ///     as a defensive guard (they are always > 0 between valid keyframes,
  ///     but this prevents any edge-case float underflow to <= 0).
  ///   - opacity is clamped to [0.0, 1.0] as a defensive guard.
  ///   - rotation uses direct lerp — no shortest-path wraparound in Phase 7.23.
  ///
  /// [VGKeyframeInterpolation.hold]:
  ///   - Returns the previous keyframe value. At or after the last keyframe,
  ///     returns the last keyframe.
  VGClipTransformDescriptor interpolatedTransformAt(int timeUs) {
    // Single keyframe — constant for all times.
    if (keyframes.length == 1) {
      return _keyframeToTransform(keyframes.first);
    }

    // Before first keyframe — clamp to first.
    if (timeUs <= keyframes.first.timeUs) {
      return _keyframeToTransform(keyframes.first);
    }

    // After last keyframe — clamp to last.
    if (timeUs >= keyframes.last.timeUs) {
      return _keyframeToTransform(keyframes.last);
    }

    // Find the bracketing keyframe pair: keyframes[i].timeUs <= timeUs < keyframes[i+1].timeUs
    int lo = 0;
    int hi = keyframes.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (keyframes[mid].timeUs <= timeUs) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    // lo and hi are now adjacent: keyframes[lo].timeUs <= timeUs < keyframes[hi].timeUs

    final kA = keyframes[lo];
    final kB = keyframes[hi];

    if (interpolation == VGKeyframeInterpolation.hold) {
      // Hold: return previous (lo) keyframe value.
      return _keyframeToTransform(kA);
    }

    // Linear interpolation.
    final spanUs = kB.timeUs - kA.timeUs;
    // spanUs is always > 0 because keyframes are strictly sorted.
    final t = (timeUs - kA.timeUs) / spanUs;

    final scaleX =
        (_lerp(kA.scaleX, kB.scaleX, t)).clamp(_kMinScale, double.maxFinite);
    final scaleY =
        (_lerp(kA.scaleY, kB.scaleY, t)).clamp(_kMinScale, double.maxFinite);
    final translationX = _lerp(kA.translationX, kB.translationX, t);
    final translationY = _lerp(kA.translationY, kB.translationY, t);
    final rotation = _lerp(kA.rotation, kB.rotation, t);
    final opacity = _lerp(kA.opacity, kB.opacity, t).clamp(0.0, 1.0);

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

  /// Converts a single keyframe snapshot to a [VGClipTransformDescriptor],
  /// incorporating the track-level anchor.
  VGClipTransformDescriptor _keyframeToTransform(
      VGTransformKeyframeDescriptor k) {
    return VGClipTransformDescriptor(
      scaleX: k.scaleX,
      scaleY: k.scaleY,
      translationX: k.translationX,
      translationY: k.translationY,
      rotation: k.rotation,
      opacity: k.opacity,
      anchorX: anchorX,
      anchorY: anchorY,
    );
  }

  // Defensive scale floor: prevents interpolated scale from reaching <= 0.
  // This should never be hit in practice since both endpoints are > 0 and
  // linear interpolation between two positive values is always positive, but
  // float rounding edge cases at t ≈ 0 or t ≈ 1 merit the guard.
  static const double _kMinScale = 1e-6;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Serialises this track to a JSON-compatible map.
  Map<String, Object> toMap() => <String, Object>{
        'interpolation': interpolation.value,
        'anchorX': anchorX,
        'anchorY': anchorY,
        'keyframes':
            keyframes.map((k) => k.toMap()).toList(growable: false),
      };

  /// Deserialises a [VGTransformTrackDescriptor] from a map produced by [toMap].
  ///
  /// Returns null if:
  ///   - 'keyframes' key is missing or not a list.
  ///   - 'keyframes' list is empty.
  ///   - Any keyframe fails [VGTransformKeyframeDescriptor.fromMap].
  ///   - Keyframes are not strictly sorted by timeUs (or contain duplicates).
  ///   - 'anchorX' or 'anchorY' are out of [0.0, 1.0].
  ///   - 'interpolation' is missing: defaults to 'linear' (not a parse failure).
  static VGTransformTrackDescriptor? fromMap(Map<Object?, Object?> map) {
    final rawKeyframes = map['keyframes'];
    if (rawKeyframes is! List) return null;
    if (rawKeyframes.isEmpty) return null;

    final keyframes = <VGTransformKeyframeDescriptor>[];
    for (final rawK in rawKeyframes) {
      Map<Object?, Object?> kMap;
      if (rawK is Map<Object?, Object?>) {
        kMap = rawK;
      } else if (rawK is Map) {
        kMap = rawK.cast<Object?, Object?>();
      } else {
        return null;
      }
      final k = VGTransformKeyframeDescriptor.fromMap(kMap);
      if (k == null) return null;
      keyframes.add(k);
    }

    if (keyframes.isEmpty) return null;

    // Validate strict sort + no duplicates after parsing.
    if (!_validateKeyframes(keyframes)) return null;

    // Anchor values — default to 0.5 (center) if absent.
    final anchorX = (map['anchorX'] as num?)?.toDouble() ?? 0.5;
    final anchorY = (map['anchorY'] as num?)?.toDouble() ?? 0.5;
    if (!anchorX.isFinite || anchorX < 0.0 || anchorX > 1.0) return null;
    if (!anchorY.isFinite || anchorY < 0.0 || anchorY > 1.0) return null;

    // Interpolation — default to linear for unknown/missing strings.
    final rawInterp = map['interpolation'];
    final interpolation = rawInterp is String
        ? VGKeyframeInterpolation.fromValue(rawInterp)
        : VGKeyframeInterpolation.linear;

    return VGTransformTrackDescriptor(
      keyframes: keyframes,
      interpolation: interpolation,
      anchorX: anchorX,
      anchorY: anchorY,
    );
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGTransformTrackDescriptor &&
          other.interpolation == interpolation &&
          other.anchorX == anchorX &&
          other.anchorY == anchorY &&
          _keyframesEqual(other.keyframes, keyframes);

  static bool _keyframesEqual(
    List<VGTransformKeyframeDescriptor> a,
    List<VGTransformKeyframeDescriptor> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        interpolation,
        anchorX,
        anchorY,
        Object.hashAll(keyframes),
      );

  @override
  String toString() => 'VGTransformTrackDescriptor('
      'interpolation: ${interpolation.value}, '
      'keyframes: ${keyframes.length}, '
      'anchor: ($anchorX, $anchorY))';
}
