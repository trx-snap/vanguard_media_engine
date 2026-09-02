// vg_overlay_transform_evaluator.dart
// Vanguard Media Engine - Phase 5 (P5-OVERLAYS-KEYFRAME-INTERP)
//
// Pure Dart static evaluator for timeline overlay keyframes and spatial transforms.

import '../../vg_overlay_descriptor.dart';
import 'vg_overlay_keyframe.dart';

/// Pure Dart static evaluator for dynamic overlay keyframe interpolation.
///
/// Evaluates timeline overlay descriptors and optional keyframe tracks at
/// any absolute timeline playhead (PTS in seconds).
class VGOverlayTransformEvaluator {
  const VGOverlayTransformEvaluator._();

  /// Validates a list of [keyframes] against an overlay's [durationSeconds].
  ///
  /// Keyframe constraints:
  /// - [durationSeconds] must be finite and > 0.0.
  /// - Each keyframe's `timeSeconds` must be finite and within `[0.0, durationSeconds]`.
  /// - All keyframe transform properties must be finite and within their valid ranges.
  /// - Keyframes must be strictly increasing in `timeSeconds` with no duplicate timestamps.
  ///
  /// Throws [ArgumentError] if any constraint is violated.
  static void validateKeyframes(
    List<VGOverlayKeyframe> keyframes,
    double durationSeconds,
  ) {
    if (!durationSeconds.isFinite || durationSeconds <= 0.0) {
      throw ArgumentError.value(
        durationSeconds,
        'durationSeconds',
        'durationSeconds must be finite and > 0.0',
      );
    }

    for (int i = 0; i < keyframes.length; i++) {
      final kf = keyframes[i];
      if (!kf.timeSeconds.isFinite ||
          kf.timeSeconds < 0.0 ||
          kf.timeSeconds > durationSeconds) {
        throw ArgumentError(
          'Keyframe at index $i has timeSeconds ${kf.timeSeconds}s out of bounds [0.0, $durationSeconds].',
        );
      }
      if (!kf.translationX.isFinite ||
          !kf.translationY.isFinite ||
          !kf.width.isFinite ||
          kf.width < 0.0 ||
          !kf.height.isFinite ||
          kf.height < 0.0 ||
          !kf.rotation.isFinite ||
          !kf.scale.isFinite ||
          kf.scale <= 0.0 ||
          !kf.opacity.isFinite ||
          kf.opacity < 0.0 ||
          kf.opacity > 1.0) {
        throw ArgumentError(
          'Keyframe at index $i has invalid transform values: $kf',
        );
      }
      if (i > 0 && kf.timeSeconds <= keyframes[i - 1].timeSeconds) {
        throw ArgumentError(
          'Keyframes must be strictly sorted by timeSeconds in ascending order with no duplicates. '
          'Keyframe at index $i (${kf.timeSeconds}s) <= keyframe at index ${i - 1} (${keyframes[i - 1].timeSeconds}s).',
        );
      }
    }
  }

  /// Evaluates a single overlay at absolute timeline [ptsSeconds].
  ///
  /// Returns `null` if [ptsSeconds] is outside the overlay descriptor's active
  /// interval `[startTimeSeconds, startTimeSeconds + durationSeconds)`.
  ///
  /// If [keyframes] is `null` or empty, returns the static transform from [overlay]
  /// wrapped in a [VGOverlayEvaluatedTransform].
  ///
  /// If [keyframes] is provided, validates them against [overlay.durationSeconds],
  /// computes overlay-local time `tLocal = ptsSeconds - overlay.startTimeSeconds`,
  /// and interpolates between the enclosing keyframes using the start keyframe's
  /// [VGOverlayInterpolation] curve:
  /// - `linear`: standard linear interpolation.
  /// - `easeInOut` / `smoothstep`: cubic smoothstep `t*t*(3-2*t)`.
  /// - `hold`: holds the previous keyframe value until the next keyframe is reached.
  /// - Clamps to the first keyframe before the first keyframe timestamp.
  /// - Clamps to the last keyframe at or after the last keyframe timestamp.
  /// - Exact keyframe timestamps return exact keyframe values.
  ///
  /// Throws [ArgumentError] if [ptsSeconds] is non-finite, or if [keyframes]
  /// fail validation.
  static VGOverlayEvaluatedTransform? evaluateOverlay({
    required VGOverlayDescriptor overlay,
    required double ptsSeconds,
    List<VGOverlayKeyframe>? keyframes,
  }) {
    if (!ptsSeconds.isFinite) {
      throw ArgumentError.value(
        ptsSeconds,
        'ptsSeconds',
        'ptsSeconds must be finite',
      );
    }

    if (!overlay.isActiveAtPTS(ptsSeconds)) {
      return null;
    }

    if (keyframes == null || keyframes.isEmpty) {
      return VGOverlayEvaluatedTransform.fromDescriptor(overlay);
    }

    validateKeyframes(keyframes, overlay.durationSeconds);

    final localTime = ptsSeconds - overlay.startTimeSeconds;

    if (keyframes.length == 1 || localTime <= keyframes.first.timeSeconds) {
      final k = keyframes.first;
      return VGOverlayEvaluatedTransform.fromDescriptor(
        overlay,
        translationX: k.translationX,
        translationY: k.translationY,
        width: k.width,
        height: k.height,
        rotation: k.rotation,
        scale: k.scale,
        opacity: k.opacity,
      );
    }

    if (localTime >= keyframes.last.timeSeconds) {
      final k = keyframes.last;
      return VGOverlayEvaluatedTransform.fromDescriptor(
        overlay,
        translationX: k.translationX,
        translationY: k.translationY,
        width: k.width,
        height: k.height,
        rotation: k.rotation,
        scale: k.scale,
        opacity: k.opacity,
      );
    }

    // Binary search for enclosing keyframe segment: keyframes[lo].timeSeconds <= localTime < keyframes[hi].timeSeconds
    int lo = 0;
    int hi = keyframes.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (keyframes[mid].timeSeconds <= localTime) {
        lo = mid;
      } else {
        hi = mid;
      }
    }

    final kA = keyframes[lo];
    final kB = keyframes[hi];

    if (kA.interpolation == VGOverlayInterpolation.hold) {
      return VGOverlayEvaluatedTransform.fromDescriptor(
        overlay,
        translationX: kA.translationX,
        translationY: kA.translationY,
        width: kA.width,
        height: kA.height,
        rotation: kA.rotation,
        scale: kA.scale,
        opacity: kA.opacity,
      );
    }

    final span = kB.timeSeconds - kA.timeSeconds;
    final progress = span == 0.0 ? 0.0 : (localTime - kA.timeSeconds) / span;

    final double p;
    switch (kA.interpolation) {
      case VGOverlayInterpolation.linear:
        p = progress;
        break;
      case VGOverlayInterpolation.easeInOut:
      case VGOverlayInterpolation.smoothstep:
        p = progress * progress * (3.0 - 2.0 * progress);
        break;
      case VGOverlayInterpolation.hold:
        p = 0.0;
        break;
    }

    final translationX = _lerp(kA.translationX, kB.translationX, p);
    final translationY = _lerp(kA.translationY, kB.translationY, p);
    final width = _lerp(kA.width, kB.width, p).clamp(0.0, double.infinity);
    final height = _lerp(kA.height, kB.height, p).clamp(0.0, double.infinity);
    final rotation = _lerp(kA.rotation, kB.rotation, p);
    final scale = _lerp(kA.scale, kB.scale, p).clamp(1e-6, double.infinity);
    final opacity = _lerp(kA.opacity, kB.opacity, p).clamp(0.0, 1.0);

    return VGOverlayEvaluatedTransform.fromDescriptor(
      overlay,
      translationX: translationX,
      translationY: translationY,
      width: width,
      height: height,
      rotation: rotation,
      scale: scale,
      opacity: opacity,
    );
  }

  /// Alias for [evaluateOverlay].
  static VGOverlayEvaluatedTransform? evaluate({
    required VGOverlayDescriptor overlay,
    required double ptsSeconds,
    List<VGOverlayKeyframe>? keyframes,
  }) => evaluateOverlay(
    overlay: overlay,
    ptsSeconds: ptsSeconds,
    keyframes: keyframes,
  );

  /// Evaluates multiple overlays at absolute timeline [ptsSeconds].
  ///
  /// Inactive overlays (where [ptsSeconds] falls outside their active interval)
  /// are filtered out.
  ///
  /// The returned list is sorted deterministically:
  /// 1. Primary: `zIndex` ascending (lower zIndex rendered first / underneath).
  /// 2. Secondary: `id` ascending (lexicographical).
  ///
  /// Throws [ArgumentError] if [ptsSeconds] is non-finite, or if any keyframe list
  /// fails validation against its corresponding overlay duration.
  static List<VGOverlayEvaluatedTransform> evaluateOverlays({
    required List<VGOverlayDescriptor> overlays,
    required double ptsSeconds,
    Map<String, List<VGOverlayKeyframe>>? keyframesByOverlayId,
  }) {
    if (!ptsSeconds.isFinite) {
      throw ArgumentError.value(
        ptsSeconds,
        'ptsSeconds',
        'ptsSeconds must be finite',
      );
    }

    final results = <VGOverlayEvaluatedTransform>[];

    for (final overlay in overlays) {
      final keyframes = keyframesByOverlayId?[overlay.id];
      final eval = evaluateOverlay(
        overlay: overlay,
        ptsSeconds: ptsSeconds,
        keyframes: keyframes,
      );
      if (eval != null) {
        results.add(eval);
      }
    }

    results.sort((a, b) {
      final zComp = a.zIndex.compareTo(b.zIndex);
      if (zComp != 0) return zComp;
      return a.id.compareTo(b.id);
    });

    return results;
  }

  /// Alias for [evaluateOverlays].
  static List<VGOverlayEvaluatedTransform> evaluateAll({
    required List<VGOverlayDescriptor> overlays,
    required double ptsSeconds,
    Map<String, List<VGOverlayKeyframe>>? keyframesByOverlayId,
  }) => evaluateOverlays(
    overlays: overlays,
    ptsSeconds: ptsSeconds,
    keyframesByOverlayId: keyframesByOverlayId,
  );

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}
