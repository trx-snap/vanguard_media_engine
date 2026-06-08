// test/vg_audio_ducking_engine_test.dart
// Phase 8.15B — VGAudioDuckingEngine unit tests.
//
// Commit-worthy.  No device required.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_audio_sidecar_plan.dart';
import 'package:vanguard_media_engine/vg_audio_ducking_engine.dart';

// ── helpers ──────────────────────────────────────────────────────────────────

VGAudioSidecarTrack _track({
  required String id,
  required String role,
  required double start,
  required double duration,
  double volume = 1.0,
  List<VGAudioVolumeKeyframe>? volumeKeyframes,
}) =>
    VGAudioSidecarTrack(
      trackId: id,
      url: '/tmp/$id.m4a',
      startTime: start,
      duration: duration,
      volume: volume,
      role: role,
      volumeKeyframes: volumeKeyframes,
    );

const _engine = VGAudioDuckingEngine();
const _cfg = VGAudioDuckingConfig(
  duckVolume: 0.25,
  attackSeconds: 0.15,
  releaseSeconds: 0.30,
  mergeGapSeconds: 0.05,
);

// ── tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── DUCK-1: No foreground tracks ──────────────────────────────────────────
  test('DUCK-1 no foreground tracks returns equivalent list', () {
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 10.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    expect(result.length, 1);
    // No foreground → no keyframes added.
    expect(result[0].volumeKeyframes, isNull);
    // Track identity preserved.
    expect(result[0].trackId, 'music1');
  });

  // ── DUCK-2: No music tracks ────────────────────────────────────────────────
  test('DUCK-2 no music tracks returns equivalent list', () {
    final tracks = [
      _track(id: 'vo1', role: 'voiceover', start: 0.0, duration: 5.0),
      _track(id: 'sfx1', role: 'sfx', start: 1.0, duration: 2.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    expect(result.length, 2);
    // SFX passes through unchanged.
    expect(result[1].volumeKeyframes, isNull);
  });

  // ── DUCK-3: Voiceover ducks overlapping music ─────────────────────────────
  test('DUCK-3 voiceover ducks overlapping music', () {
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 10.0),
      _track(id: 'vo1', role: 'voiceover', start: 3.0, duration: 4.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);

    final music = result.firstWhere((t) => t.trackId == 'music1');
    expect(music.volumeKeyframes, isNotNull);
    expect(music.volumeKeyframes!.isNotEmpty, isTrue);

    // Opening keyframe must be at trackStart with normal volume.
    final first = music.volumeKeyframes!.first;
    expect(first.time, closeTo(0.0, 1e-9));
    expect(first.volume, closeTo(1.0, 1e-9));

    // There must be a keyframe at duckVolume during the voiceover window.
    final ducked = music.volumeKeyframes!.where((kf) =>
        kf.volume < 0.5 && kf.time >= 3.0 - 0.15 && kf.time <= 7.0 + 0.30);
    expect(ducked.isNotEmpty, isTrue,
        reason: 'Expected a dipped keyframe around the voiceover window');

    // Closing keyframe must return to normal.
    final last = music.volumeKeyframes!.last;
    expect(last.volume, closeTo(1.0, 1e-9));
    expect(last.time, closeTo(10.0, 1e-9));
  });

  // ── DUCK-4: Original audio ducks overlapping music ────────────────────────
  test('DUCK-4 original audio ducks overlapping music', () {
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 8.0),
      _track(id: 'orig1', role: 'original', start: 2.0, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final music = result.firstWhere((t) => t.trackId == 'music1');
    expect(music.volumeKeyframes, isNotNull);
    expect(music.volumeKeyframes!.any((kf) => kf.volume < 0.5), isTrue);
  });

  // ── DUCK-5: Non-overlapping foreground does not duck music ────────────────
  test('DUCK-5 non-overlapping foreground does not duck music', () {
    // Music: 0–5s.  Voiceover: 6–9s.  No overlap.
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 5.0),
      _track(id: 'vo1', role: 'voiceover', start: 6.0, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final music = result.firstWhere((t) => t.trackId == 'music1');
    expect(music.volumeKeyframes, isNull,
        reason: 'No overlap → no keyframes expected');
  });

  // ── DUCK-6: Overlapping foreground intervals are merged ───────────────────
  test('DUCK-6 overlapping foreground intervals are merged into one duck', () {
    // Two voiceovers that overlap each other.
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 20.0),
      _track(id: 'vo1', role: 'voiceover', start: 2.0, duration: 4.0),
      _track(id: 'vo2', role: 'voiceover', start: 4.5, duration: 4.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final music = result.firstWhere((t) => t.trackId == 'music1');
    final kfs = music.volumeKeyframes!;

    // Count the number of dip-to-duckVolume segments.
    int dipCount = 0;
    for (var i = 0; i < kfs.length; i++) {
      if ((kfs[i].volume - _cfg.duckVolume).abs() < 1e-9) {
        // This is a dipped keyframe. Count each "entry into duck" by checking
        // the previous keyframe had higher volume.
        if (i == 0 || kfs[i - 1].volume > _cfg.duckVolume + 1e-9) {
          dipCount++;
        }
      }
    }
    // The two overlapping voiceovers should produce only one dip entry.
    expect(dipCount, 1,
        reason: 'Merged intervals should produce a single duck envelope');
  });

  // ── DUCK-7: Near-adjacent intervals merged by threshold ───────────────────
  test('DUCK-7 near-adjacent foreground intervals are merged by gap threshold',
      () {
    // Gap between vo1 end (5.0) and vo2 start (5.03) = 0.03s < mergeGap 0.05s.
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 20.0),
      _track(id: 'vo1', role: 'voiceover', start: 2.0, duration: 3.0),
      _track(id: 'vo2', role: 'voiceover', start: 5.03, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final kfs = result
        .firstWhere((t) => t.trackId == 'music1')
        .volumeKeyframes!;

    int dipEntries = 0;
    for (var i = 1; i < kfs.length; i++) {
      if (kfs[i - 1].volume > _cfg.duckVolume + 1e-9 &&
          (kfs[i].volume - _cfg.duckVolume).abs() < 1e-9) {
        dipEntries++;
      }
    }
    expect(dipEntries, 1,
        reason: 'Near-adjacent intervals should merge into one duck');
  });

  // ── DUCK-8: Keyframes clamp to music track range ──────────────────────────
  test('DUCK-8 generated keyframes are clamped to music track range', () {
    // Voiceover starts before the music track.
    final tracks = [
      _track(id: 'music1', role: 'music', start: 5.0, duration: 5.0), // 5–10
      _track(id: 'vo1', role: 'voiceover', start: 0.0, duration: 7.0), // 0–7
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final music = result.firstWhere((t) => t.trackId == 'music1');
    final kfs = music.volumeKeyframes!;

    for (final kf in kfs) {
      expect(kf.time, greaterThanOrEqualTo(5.0 - 1e-9));
      expect(kf.time, lessThanOrEqualTo(10.0 + 1e-9));
    }
  });

  // ── DUCK-9: Multiple music tracks handled independently ───────────────────
  test('DUCK-9 multiple music tracks are ducked independently', () {
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 10.0),
      _track(id: 'music2', role: 'music', start: 0.0, duration: 10.0),
      _track(id: 'vo1', role: 'voiceover', start: 2.0, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final m1 = result.firstWhere((t) => t.trackId == 'music1');
    final m2 = result.firstWhere((t) => t.trackId == 'music2');
    expect(m1.volumeKeyframes, isNotNull);
    expect(m2.volumeKeyframes, isNotNull);
    // Both must contain dipped segments.
    expect(m1.volumeKeyframes!.any((kf) => kf.volume < 0.5), isTrue);
    expect(m2.volumeKeyframes!.any((kf) => kf.volume < 0.5), isTrue);
  });

  // ── DUCK-10: Non-music tracks are unchanged ────────────────────────────────
  test('DUCK-10 non-music tracks are passed through unchanged', () {
    final original = _track(id: 'sfx1', role: 'sfx', start: 0.0, duration: 5.0);
    final tracks = [
      original,
      _track(id: 'vo1', role: 'voiceover', start: 1.0, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final sfx = result.firstWhere((t) => t.trackId == 'sfx1');
    expect(sfx, equals(original));
  });

  // ── DUCK-11: Existing volumeKeyframes on music track preserved ─────────────
  test('DUCK-11 music track with existing volumeKeyframes is not overwritten',
      () {
    final existingKfs = [
      const VGAudioVolumeKeyframe(time: 0.0, volume: 0.8),
      const VGAudioVolumeKeyframe(time: 5.0, volume: 0.8),
    ];
    final original = _track(
      id: 'music1',
      role: 'music',
      start: 0.0,
      duration: 10.0,
      volumeKeyframes: existingKfs,
    );
    final tracks = [
      original,
      _track(id: 'vo1', role: 'voiceover', start: 2.0, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final music = result.firstWhere((t) => t.trackId == 'music1');
    // Must be exactly the same track object (no new keyframes).
    expect(identical(music, original), isTrue,
        reason: 'Pre-authored keyframes must not be replaced');
  });

  // ── DUCK-12: Engine does not mutate input list or track objects ────────────
  test('DUCK-12 engine does not mutate input list or track objects', () {
    final music = _track(id: 'music1', role: 'music', start: 0.0, duration: 10.0);
    final vo = _track(id: 'vo1', role: 'voiceover', start: 2.0, duration: 3.0);
    final inputList = [music, vo];

    _engine.apply(inputList, config: _cfg);

    // Input list length unchanged.
    expect(inputList.length, 2);
    // Input track objects unchanged.
    expect(music.volumeKeyframes, isNull);
    expect(vo.volumeKeyframes, isNull);
    // Same object references.
    expect(identical(inputList[0], music), isTrue);
    expect(identical(inputList[1], vo), isTrue);
  });

  // ── DUCK-13: Configurable duck volume reflected in output ──────────────────
  test('DUCK-13 configurable duckVolume is reflected in keyframes', () {
    const customCfg = VGAudioDuckingConfig(
      duckVolume: 0.10,
      attackSeconds: 0.20,
      releaseSeconds: 0.40,
    );
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 10.0),
      _track(id: 'vo1', role: 'voiceover', start: 3.0, duration: 2.0),
    ];
    final result = _engine.apply(tracks, config: customCfg);
    final music = result.firstWhere((t) => t.trackId == 'music1');
    final minVolume =
        music.volumeKeyframes!.map((kf) => kf.volume).reduce(
              (a, b) => a < b ? a : b,
            );
    expect(minVolume, closeTo(0.10, 1e-9));
  });

  // ── DUCK-14: Custom attack / release reflected in keyframe timing ──────────
  test('DUCK-14 custom attack and release durations appear in keyframe times',
      () {
    const customCfg = VGAudioDuckingConfig(
      duckVolume: 0.25,
      attackSeconds: 0.50,
      releaseSeconds: 1.0,
    );
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 20.0),
      _track(id: 'vo1', role: 'voiceover', start: 5.0, duration: 4.0),
    ];
    final result = _engine.apply(tracks, config: customCfg);
    final kfs = result
        .firstWhere((t) => t.trackId == 'music1')
        .volumeKeyframes!;

    // Expected ramp-down start: 5.0 - 0.5 = 4.5.
    expect(
      kfs.any((kf) => (kf.time - 4.5).abs() < 1e-9 && kf.volume > 0.5),
      isTrue,
      reason: 'Expected normal-volume keyframe at ramp-down start (t=4.5)',
    );
    // Expected ramp-up end: 9.0 + 1.0 = 10.0.
    expect(
      kfs.any((kf) => (kf.time - 10.0).abs() < 1e-9 && kf.volume > 0.5),
      isTrue,
      reason: 'Expected normal-volume keyframe at ramp-up end (t=10.0)',
    );
  });

  // ── DUCK-15: Output is serializable through VGAudioSidecarPlan ────────────
  test('DUCK-15 output is serializable through VGAudioSidecarPlan.toMap()',
      () {
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 10.0),
      _track(id: 'vo1', role: 'voiceover', start: 2.0, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final plan = VGAudioSidecarPlan(tracks: result);
    final map = plan.toMap();

    // Round-trip.
    final restored = VGAudioSidecarPlan.fromMap(
      map.cast<Object?, Object?>(),
    );
    expect(restored, isNotNull);
    expect(restored!.tracks.length, 2);

    final restoredMusic =
        restored.tracks.firstWhere((t) => t.trackId == 'music1');
    expect(restoredMusic.volumeKeyframes, isNotNull);
    expect(restoredMusic.volumeKeyframes!.isNotEmpty, isTrue);
  });

  // ── DUCK-16: Rolelass tracks (role == null) pass through unchanged ─────────
  test('DUCK-16 tracks without a role are not altered', () {
    final noRole = VGAudioSidecarTrack(
      trackId: 'ambient',
      url: '/tmp/ambient.m4a',
      startTime: 0.0,
      duration: 10.0,
    );
    final tracks = [
      noRole,
      _track(id: 'vo1', role: 'voiceover', start: 1.0, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    expect(identical(result[0], noRole), isTrue);
  });

  // ── DUCK-17: Music track that starts before and ends after foreground ──────
  test('DUCK-17 music fully enclosing foreground is ducked in the middle', () {
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 20.0),
      _track(id: 'vo1', role: 'voiceover', start: 8.0, duration: 4.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final kfs = result
        .firstWhere((t) => t.trackId == 'music1')
        .volumeKeyframes!;

    // First keyframe: t=0, volume=1.
    expect(kfs.first.time, closeTo(0.0, 1e-9));
    expect(kfs.first.volume, closeTo(1.0, 1e-9));

    // Last keyframe: t=20, volume=1.
    expect(kfs.last.time, closeTo(20.0, 1e-9));
    expect(kfs.last.volume, closeTo(1.0, 1e-9));

    // There should be a dip somewhere in the middle.
    expect(kfs.any((kf) => kf.volume < 0.5), isTrue);
  });
}
