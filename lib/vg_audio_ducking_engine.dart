// vg_audio_ducking_engine.dart
// Vanguard Media Engine — Phase 8.15B Automated Audio Ducking Engine
//
// Pure-Dart offline utility.  No channel calls, no rendering logic.
// Takes a List<VGAudioSidecarTrack> and returns a new list where 'music'
// tracks gain VGAudioVolumeKeyframe automation that ducks around foreground
// ('voiceover', 'original') intervals.
//
// Design rules:
//   - Immutable: does not mutate input tracks or input list.
//   - Does not overwrite existing non-empty volumeKeyframes on music tracks.
//   - Timing is in output-timeline seconds (same basis as VGAudioSidecarTrack.startTime).
//   - No native calls, no Phase 15 audio graph work, no real-time playback ducking.
//   - Only 'linear' keyframe curves are used (matches Phase 8.15A constraint).

import 'vg_audio_sidecar_plan.dart';

/// Configuration for [VGAudioDuckingEngine.apply].
///
/// All timing values are in seconds.  Defaults match a broadcast-standard
/// light-duck profile (–12 dB equivalent in linear gain).
final class VGAudioDuckingConfig {
  const VGAudioDuckingConfig({
    this.duckVolume = 0.25,
    this.attackSeconds = 0.15,
    this.releaseSeconds = 0.30,
    this.mergeGapSeconds = 0.05,
  })  : assert(duckVolume >= 0.0 && duckVolume <= 1.0,
            'duckVolume must be in [0, 1]'),
        assert(attackSeconds >= 0.0, 'attackSeconds must be >= 0'),
        assert(releaseSeconds >= 0.0, 'releaseSeconds must be >= 0'),
        assert(mergeGapSeconds >= 0.0, 'mergeGapSeconds must be >= 0');

  /// Target gain for the music track while a foreground track is playing.
  /// 0.0 = silence, 1.0 = no duck.  Default 0.25 (≈ –12 dB).
  final double duckVolume;

  /// Duration of the fade-down ramp from full volume to [duckVolume].
  final double attackSeconds;

  /// Duration of the fade-up ramp from [duckVolume] back to full volume.
  final double releaseSeconds;

  /// Foreground intervals closer than this threshold are merged into one
  /// before keyframes are generated.  Prevents rapid duck/unduck chattering.
  final double mergeGapSeconds;
}

/// A closed time interval [start, end] in output-timeline seconds.
final class _Interval {
  const _Interval(this.start, this.end) : assert(start <= end);
  final double start;
  final double end;
}

/// Phase 8.15B offline audio ducking engine.
///
/// Call [apply] with the current track list and a [VGAudioDuckingConfig].
/// Returns a new track list.  The input list and input track objects are
/// never mutated.
///
/// **Foreground roles** (trigger ducking): `'voiceover'`, `'original'`.
/// **Background role** (gets ducked): `'music'`.
/// All other roles and tracks without a role are passed through unchanged.
///
/// **Skip condition**: if a music track already has non-empty [volumeKeyframes],
/// it is returned unchanged.  Callers that pre-authored keyframe automation
/// retain full control.
///
/// **No-overlap condition**: if no foreground interval overlaps a music track's
/// effective output range, the track is returned unchanged (no keyframes added).
final class VGAudioDuckingEngine {
  const VGAudioDuckingEngine();

  /// Applies offline ducking to [tracks] using [config].
  ///
  /// Returns a new [List<VGAudioSidecarTrack>].  All non-music tracks and
  /// music tracks with pre-authored keyframes are included unchanged.
  List<VGAudioSidecarTrack> apply(
    List<VGAudioSidecarTrack> tracks, {
    VGAudioDuckingConfig config = const VGAudioDuckingConfig(),
  }) {
    // 1. Collect foreground intervals from voiceover + original tracks.
    final foregroundIntervals = <_Interval>[];
    for (final t in tracks) {
      if (t.role == 'voiceover' || t.role == 'original') {
        final start = t.startTime;
        final end = t.startTime + t.duration;
        if (end > start) {
          foregroundIntervals.add(_Interval(start, end));
        }
      }
    }

    // 2. Merge overlapping / near-adjacent foreground intervals.
    final merged = _mergeIntervals(foregroundIntervals, config.mergeGapSeconds);

    // 3. Process each track.
    return tracks.map((t) {
      if (t.role != 'music') return t;                    // pass through
      if (t.volumeKeyframes != null && t.volumeKeyframes!.isNotEmpty) {
        return t; // pre-authored, skip
      }

      return _duckTrack(t, merged, config);
    }).toList();
  }

  // ── private helpers ────────────────────────────────────────────────────────

  /// Merges a list of intervals: sorts by start, then merges any pair whose
  /// gap is ≤ [gapThreshold].
  static List<_Interval> _mergeIntervals(
    List<_Interval> intervals,
    double gapThreshold,
  ) {
    if (intervals.isEmpty) return const [];

    final sorted = List<_Interval>.from(intervals)
      ..sort((a, b) => a.start.compareTo(b.start));

    final result = <_Interval>[sorted.first];
    for (var i = 1; i < sorted.length; i++) {

      final current = sorted[i];
      final last = result.last;
      if (current.start <= last.end + gapThreshold) {
        // Extend last to cover current.
        result[result.length - 1] = _Interval(
          last.start,
          current.end > last.end ? current.end : last.end,
        );
      } else {
        result.add(current);
      }
    }
    return result;
  }

  /// Generates volume keyframes for a single music track given the merged
  /// foreground intervals.  Returns the track unchanged when no overlap exists.
  static VGAudioSidecarTrack _duckTrack(
    VGAudioSidecarTrack track,
    List<_Interval> foreground,
    VGAudioDuckingConfig config,
  ) {
    final trackStart = track.startTime;
    final trackEnd = track.startTime + track.duration;
    final normalVolume = track.volume; // hold this as the baseline

    // Collect only foreground intervals that overlap this track's range.
    final overlaps = foreground
        .where((f) => f.end > trackStart && f.start < trackEnd)
        .toList();

    if (overlaps.isEmpty) return track; // no duck needed

    // Build keyframe list.  We walk the track timeline chronologically,
    // emitting hold-at-normal, ramp-down, hold-at-duck, ramp-up segments.
    final keyframes = <VGAudioVolumeKeyframe>[];
    double cursor = trackStart;

    // Opening keyframe: start at normal volume.
    keyframes.add(VGAudioVolumeKeyframe(time: trackStart, volume: normalVolume));

    for (final interval in overlaps) {
      // ── attack ──────────────────────────────────────────────
      // The ramp-down starts [attackSeconds] before the foreground interval.
      // Clamp to the track range and to not go before cursor.
      final rampDownStart = _clamp(
        interval.start - config.attackSeconds,
        trackStart,
        trackEnd,
      );
      final rampDownEnd = _clamp(interval.start, trackStart, trackEnd);

      if (rampDownStart > cursor + 1e-6) {
        // Hold normal volume up to the start of the ramp.
        keyframes.add(
          VGAudioVolumeKeyframe(time: rampDownStart, volume: normalVolume),
        );
      }
      if (rampDownEnd > rampDownStart + 1e-6) {
        // End of ramp-down: duckVolume at foreground start.
        keyframes.add(
          VGAudioVolumeKeyframe(time: rampDownEnd, volume: config.duckVolume),
        );
      }

      // ── hold duck ────────────────────────────────────────────
      final holdEnd = _clamp(interval.end, trackStart, trackEnd);
      if (holdEnd > rampDownEnd + 1e-6) {
        keyframes.add(
          VGAudioVolumeKeyframe(time: holdEnd, volume: config.duckVolume),
        );
      }

      // ── release ───────────────────────────────────────────────
      final rampUpEnd = _clamp(
        interval.end + config.releaseSeconds,
        trackStart,
        trackEnd,
      );
      if (rampUpEnd > holdEnd + 1e-6) {
        keyframes.add(
          VGAudioVolumeKeyframe(time: rampUpEnd, volume: normalVolume),
        );
      }

      cursor = rampUpEnd;
    }

    // Closing keyframe: hold normal volume to track end (if not already there).
    final lastKf = keyframes.last;
    if (trackEnd - lastKf.time > 1e-6) {
      keyframes.add(VGAudioVolumeKeyframe(time: trackEnd, volume: normalVolume));
    }

    // De-duplicate consecutive keyframes at the same time that have the same
    // volume (can arise when attack/release exactly align with track bounds).
    final deduped = _dedup(keyframes);

    return VGAudioSidecarTrack(
      trackId: track.trackId,
      url: track.url,
      startTime: track.startTime,
      duration: track.duration,
      volume: track.volume,
      role: track.role,
      fadeInSeconds: track.fadeInSeconds,
      fadeOutSeconds: track.fadeOutSeconds,
      timeRemapAudioPolicy: track.timeRemapAudioPolicy,
      sourceTrimStartSeconds: track.sourceTrimStartSeconds,
      volumeKeyframes: deduped,
    );
  }

  static double _clamp(double v, double min, double max) =>
      v < min ? min : (v > max ? max : v);

  /// Removes consecutive keyframes at the same time and volume.
  static List<VGAudioVolumeKeyframe> _dedup(
      List<VGAudioVolumeKeyframe> kfs) {
    if (kfs.length <= 1) return kfs;
    final out = <VGAudioVolumeKeyframe>[kfs.first];
    for (var i = 1; i < kfs.length; i++) {
      final prev = out.last;
      final curr = kfs[i];
      if ((curr.time - prev.time).abs() < 1e-9 &&
          (curr.volume - prev.volume).abs() < 1e-9) {
        continue; // exact duplicate, skip
      }
      out.add(curr);
    }
    return out;
  }
}
