// vg_roi_keyframe_sidecar_builder.dart
// UMF V2 Animated / Keyframed ROI Sidecar Builder (P5-ANIM-ROI-KEYFRAME-INTERP)
//
// Generates a server-ready export-space VGROISidecar by interpolating across
// time-varying export_output_normalized ROI keyframes.
//
// Design rules (P5-ANIM-ROI):
//   - Pure Dart. No native calls. No Flutter rendering dependencies.
//   - Keyframes and generated samples are strictly in export_output_normalized space.
//   - Never exposes or serializes capture/source coordinates.
//   - Interpolation curves supported: linear, easeInOut / smoothstep, hold.
//   - Segments with missing/null endpoint boxes produce null boxes rather than inventing boxes.
//   - Fail-closed: invalid inputs or duplicate keyframe timestamps throw ArgumentError.
//   - Deterministic strictly ascending output samples without duplicate timestamps.
//   - Empty or all-null keyframes produce a valid finalized empty sidecar (samples: [], coverage: 0.0).

import 'vg_roi_models.dart';

/// Pure Dart builder that interpolates export-space ROI keyframes into a finalized [VGROISidecar].
class VGROIKeyframeSidecarBuilder {
  const VGROIKeyframeSidecarBuilder._();

  /// Builds an export-space [VGROISidecar] from time-varying [keyframes] over [durationMs].
  ///
  /// ## Parameters
  /// - [durationMs]: Total duration of the media in milliseconds. Must be > 0.
  /// - [outputWidth]: Width of the export canvas in pixels. Must be > 0.
  /// - [outputHeight]: Height of the export canvas in pixels. Must be > 0.
  /// - [keyframes]: List of [VGROIKeyframe] instances. Keyframes must have non-negative
  ///   timestamps within `[0, durationMs]` and must not have duplicate timestamps.
  /// - [sampleIntervalMs]: Interval in milliseconds between generated samples. Must be > 0. Defaults to 33ms (~30fps).
  /// - [recordingSessionId]: Optional session identifier. Defaults to `'animated_roi_export'`.
  /// - [platform]: Target platform string. Defaults to `'android'`.
  /// - [sourceType]: Source type identifier. Defaults to `'animated_keyframe'`.
  /// - [version]: Sidecar format version. Defaults to 1.
  ///
  /// ## Returns
  /// A finalized [VGROISidecar] with `coordinateSpace == 'export_output_normalized'`.
  /// If [keyframes] is empty or all keyframes have a `null` box, returns a valid finalized
  /// empty sidecar with `samples == []` and `coverage.coveragePercent == 0.0`.
  ///
  /// ## Throws
  /// [ArgumentError] if [durationMs], [outputWidth], [outputHeight], or [sampleIntervalMs] are non-positive,
  /// or if any keyframe has an out-of-range timestamp, or if duplicate timestamps exist.
  static VGROISidecar build({
    required int durationMs,
    required int outputWidth,
    required int outputHeight,
    required List<VGROIKeyframe> keyframes,
    int sampleIntervalMs = 33,
    String? recordingSessionId,
    String platform = 'android',
    String sourceType = 'animated_keyframe',
    int version = 1,
  }) {
    if (durationMs <= 0) {
      throw ArgumentError('durationMs must be greater than zero.');
    }
    if (outputWidth <= 0) {
      throw ArgumentError('outputWidth must be greater than zero.');
    }
    if (outputHeight <= 0) {
      throw ArgumentError('outputHeight must be greater than zero.');
    }
    if (sampleIntervalMs <= 0) {
      throw ArgumentError('sampleIntervalMs must be greater than zero.');
    }
    if (sourceType.isEmpty) {
      throw ArgumentError('sourceType must not be empty.');
    }
    if (platform.isEmpty) {
      throw ArgumentError('platform must not be empty.');
    }
    if (version <= 0) {
      throw ArgumentError('version must be greater than zero.');
    }

    final effectiveSessionId = recordingSessionId ?? 'animated_roi_export';

    // Sort keyframes deterministically and validate boundaries & uniqueness
    final sortedKeyframes = List<VGROIKeyframe>.from(keyframes)
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    for (int i = 0; i < sortedKeyframes.length; i++) {
      final kf = sortedKeyframes[i];
      if (kf.timestampMs < 0 || kf.timestampMs > durationMs) {
        throw ArgumentError(
          'Keyframe timestamp ${kf.timestampMs}ms is out of bounds [0, $durationMs].',
        );
      }
      if (i > 0 && kf.timestampMs == sortedKeyframes[i - 1].timestampMs) {
        throw ArgumentError(
          'Duplicate keyframe timestamp at ${kf.timestampMs}ms.',
        );
      }
    }

    // Valid empty sidecar fallback if no usable ROI keyframe exists
    final hasUsableBox = sortedKeyframes.any((kf) => kf.box != null);
    if (sortedKeyframes.isEmpty || !hasUsableBox) {
      return VGROISidecar(
        version: version,
        sourceType: sourceType,
        platform: platform,
        coordinateSpace: 'export_output_normalized',
        recordingSessionId: effectiveSessionId,
        videoIdentity: VGROIIdentity(
          durationMs: durationMs,
          width: outputWidth,
          height: outputHeight,
          hash: null,
        ),
        coverage: VGROICoverage(
          coveragePercent: 0.0,
          missingIntervals: const [],
        ),
        samples: const [],
        finalized: true,
      );
    }

    // Collect sorted, deduplicated sample timestamps clamped to [0, durationMs]
    final timestampSet = <int>{0, durationMs};
    for (int t = 0; t <= durationMs; t += sampleIntervalMs) {
      timestampSet.add(t);
    }
    for (final kf in sortedKeyframes) {
      timestampSet.add(kf.timestampMs);
    }
    final sortedTimestamps = timestampSet.toList()..sort();

    // Generate samples
    final samples = <VGROISample>[];
    for (final t in sortedTimestamps) {
      samples.add(
        _evaluateSampleAt(timestampMs: t, keyframes: sortedKeyframes),
      );
    }

    final nonNullCount = samples.where((s) => s.box != null).length;
    final coveragePercent = samples.isEmpty
        ? 0.0
        : nonNullCount / samples.length;

    return VGROISidecar(
      version: version,
      sourceType: sourceType,
      platform: platform,
      coordinateSpace: 'export_output_normalized',
      recordingSessionId: effectiveSessionId,
      videoIdentity: VGROIIdentity(
        durationMs: durationMs,
        width: outputWidth,
        height: outputHeight,
        hash: null,
      ),
      coverage: VGROICoverage(
        coveragePercent: coveragePercent,
        missingIntervals: const [],
      ),
      samples: samples,
      finalized: true,
    );
  }

  /// Interpolates a [VGROIBox] between [start] and [end] at progress [t] in `[0.0, 1.0]`.
  static VGROIBox interpolateBox({
    required VGROIBox start,
    required VGROIBox end,
    required double t,
    VGROIKeyframeInterpolation interpolation =
        VGROIKeyframeInterpolation.linear,
  }) {
    if (t <= 0.0) return start;
    if (t >= 1.0) return end;

    double p;
    switch (interpolation) {
      case VGROIKeyframeInterpolation.linear:
        p = t;
        break;
      case VGROIKeyframeInterpolation.easeInOut:
      case VGROIKeyframeInterpolation.smoothstep:
        p = t * t * (3.0 - 2.0 * t);
        break;
      case VGROIKeyframeInterpolation.hold:
        p = 0.0;
        break;
    }

    final ix = start.x + (end.x - start.x) * p;
    final iy = start.y + (end.y - start.y) * p;
    final iw = start.w + (end.w - start.w) * p;
    final ih = start.h + (end.h - start.h) * p;

    final safeX = ix.clamp(0.0, 1.0);
    final safeY = iy.clamp(0.0, 1.0);
    final safeW = iw.clamp(0.0, (1.0 - safeX).clamp(0.0, 1.0));
    final safeH = ih.clamp(0.0, (1.0 - safeY).clamp(0.0, 1.0));

    return VGROIBox(x: safeX, y: safeY, w: safeW, h: safeH);
  }

  static VGROISample _evaluateSampleAt({
    required int timestampMs,
    required List<VGROIKeyframe> keyframes,
  }) {
    // Exact keyframe match
    for (final kf in keyframes) {
      if (kf.timestampMs == timestampMs) {
        return VGROISample(
          timestampMs: timestampMs,
          framePtsMs: timestampMs,
          recordingRelativeMs: timestampMs,
          box: kf.box,
          quality: kf.quality ?? (kf.box != null ? 'stable' : 'missing'),
          confidence: kf.confidence,
          paddingPolicy: kf.paddingPolicy,
        );
      }
    }

    // Outside keyframed range: no invented boxes
    if (timestampMs < keyframes.first.timestampMs ||
        timestampMs > keyframes.last.timestampMs) {
      return VGROISample(
        timestampMs: timestampMs,
        framePtsMs: timestampMs,
        recordingRelativeMs: timestampMs,
        box: null,
        quality: 'missing',
        confidence: null,
        paddingPolicy: null,
      );
    }

    // Locate enclosing segment
    VGROIKeyframe? prev;
    VGROIKeyframe? next;
    for (int i = 0; i < keyframes.length - 1; i++) {
      if (keyframes[i].timestampMs < timestampMs &&
          keyframes[i + 1].timestampMs > timestampMs) {
        prev = keyframes[i];
        next = keyframes[i + 1];
        break;
      }
    }

    if (prev == null || next == null) {
      return VGROISample(
        timestampMs: timestampMs,
        framePtsMs: timestampMs,
        recordingRelativeMs: timestampMs,
        box: null,
        quality: 'missing',
        confidence: null,
        paddingPolicy: null,
      );
    }

    // If either endpoint is missing/null, intermediate samples must be null
    if (prev.box == null || next.box == null) {
      return VGROISample(
        timestampMs: timestampMs,
        framePtsMs: timestampMs,
        recordingRelativeMs: timestampMs,
        box: null,
        quality: 'missing',
        confidence: null,
        paddingPolicy: null,
      );
    }

    final span = next.timestampMs - prev.timestampMs;
    final progress = span == 0 ? 0.0 : (timestampMs - prev.timestampMs) / span;

    final interpolatedBox = interpolateBox(
      start: prev.box!,
      end: next.box!,
      t: progress,
      interpolation: prev.interpolation,
    );

    double? interpolatedConfidence;
    if (prev.confidence != null && next.confidence != null) {
      interpolatedConfidence =
          (prev.confidence! + (next.confidence! - prev.confidence!) * progress)
              .clamp(0.0, 1.0);
    } else {
      interpolatedConfidence = prev.confidence ?? next.confidence;
    }

    return VGROISample(
      timestampMs: timestampMs,
      framePtsMs: timestampMs,
      recordingRelativeMs: timestampMs,
      box: interpolatedBox,
      quality: 'interpolated',
      confidence: interpolatedConfidence,
      paddingPolicy: prev.paddingPolicy ?? next.paddingPolicy,
    );
  }
}
