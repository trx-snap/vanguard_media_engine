// vg_audio_ducking_engine.dart
// Vanguard Media Engine — Phase 8.15B Automated Audio Ducking Engine
//                         Phase 10-C Slice B: VO-triggered ducking only.
//
// Pure-Dart offline utility.  No channel calls, no rendering logic.
// Takes a List<VGAudioSidecarTrack> and returns a new list where known Added
// tracks ('music', 'sfx') gain VGAudioVolumeKeyframe automation that ducks
// around voiceover intervals.
//
// Phase 10-C Slice B role classification:
//   Foreground trigger (causes ducking): 'voiceover' ONLY.
//   Ducking targets (get keyframes):     'music', 'sfx'.
//   Pass-through unchanged:              'original', null, any unknown string.
//
// 'original' static muting is owned by VGEditorDraft.applyAudioCompositionPolicy(),
// not by this engine.  The engine never modifies 'original' tracks.
//
// Design rules:
//   - Immutable: does not mutate input tracks or input list.
//   - Does not overwrite existing non-empty volumeKeyframes on 'music'/'sfx' tracks
//     (Slice B limitation: no provenance distinguishes user-authored from generated
//     ducking automation; full composition of user automation and system ducking is
//     deferred to a future slice).
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

/// Phase 8.15B / Phase 10-C Slice B offline audio ducking engine.
///
/// Call [apply] with the current track list and a [VGAudioDuckingConfig].
/// Returns a new track list.  The input list and input track objects are
/// never mutated.
///
/// **Foreground role** (triggers ducking): `'voiceover'` ONLY.
/// **Ducking targets** (receive generated keyframes): `'music'`, `'sfx'`.
/// **Pass-through unchanged**: `'original'`, null, or any unknown role string.
///
/// Static muting of `'original'` tracks is the responsibility of
/// [VGEditorDraft.applyAudioCompositionPolicy], not this engine.
///
/// **Skip condition** (Slice B): if a `'music'` or `'sfx'` track already has
/// non-empty [volumeKeyframes], it is returned unchanged.  No provenance
/// currently distinguishes user-authored automation from previously generated
/// ducking; full automation composition is deferred to a future slice.
///
/// **No-overlap condition**: if no voiceover interval overlaps a target
/// track's effective output range, the track is returned unchanged.
final class VGAudioDuckingEngine {
  const VGAudioDuckingEngine();

  /// Applies offline ducking to [tracks] using [config].
  ///
  /// Returns a new [List<VGAudioSidecarTrack>].  Tracks with roles other than
  /// `'music'` and `'sfx'`, and target tracks with pre-authored keyframes, are
  /// included unchanged.
  List<VGAudioSidecarTrack> apply(
    List<VGAudioSidecarTrack> tracks, {
    VGAudioDuckingConfig config = const VGAudioDuckingConfig(),
  }) {
    // 1. Collect foreground intervals from voiceover tracks ONLY.
    //    'original' is no longer a foreground trigger (Phase 10-C Slice B).
    //    Static muting of 'original' is handled by applyAudioCompositionPolicy.
    final foregroundIntervals = <_Interval>[];
    for (final t in tracks) {
      if (t.role == 'voiceover') {
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
      // Only 'music' and 'sfx' are known Added roles that receive ducking.
      // 'original', 'voiceover', null, and unknown role strings pass through.
      if (!_isKnownAddedRole(t.role)) return t;
      // Slice B: skip tracks with existing keyframes — no provenance to
      // distinguish user-authored automation from generated ducking.
      if (t.volumeKeyframes != null && t.volumeKeyframes!.isNotEmpty) {
        return t; // pre-authored automation preserved, ducking skipped
      }

      return _duckTrack(t, merged, config);
    }).toList();
  }

  // ── Role classification helpers ────────────────────────────────────────────

  /// Returns `true` if [role] is a known Added-lane role that ducks under VO.
  ///
  /// Only `'music'` and `'sfx'` are currently known Added roles.
  /// Null and unknown strings are explicitly excluded — they pass through
  /// unchanged and are not automatic ducking targets.
  static bool _isKnownAddedRole(String? role) =>
      role == 'music' || role == 'sfx';

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
