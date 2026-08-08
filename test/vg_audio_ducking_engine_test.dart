// test/vg_audio_ducking_engine_test.dart
// Phase 8.15B — VGAudioDuckingEngine unit tests.
// Phase 10-C Slice B — updated for VO-only foreground trigger and
//                      music+sfx-only ducking targets.
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
  double mixGain = 1.0,
}) => VGAudioSidecarTrack(
  trackId: id,
  url: '/tmp/$id.m4a',
  startTime: start,
  duration: duration,
  volume: volume,
  role: role,
  volumeKeyframes: volumeKeyframes,
  mixGain: mixGain,
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

  // ── DUCK-2: SFX ducks under voiceover (Phase 10-C Slice B) ───────────────
  // SFX is a known Added role and must duck under VO, unlike the old
  // Phase 8.15B behaviour where SFX passed through unchanged.
  test('DUCK-2 sfx ducks under voiceover', () {
    final tracks = [
      _track(id: 'vo1', role: 'voiceover', start: 0.0, duration: 5.0),
      _track(id: 'sfx1', role: 'sfx', start: 1.0, duration: 2.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    expect(result.length, 2);
    final sfx = result.firstWhere((t) => t.trackId == 'sfx1');
    // SFX is inside the voiceover window: it should receive ducking keyframes.
    expect(sfx.volumeKeyframes, isNotNull);
    expect(sfx.volumeKeyframes!.isNotEmpty, isTrue);
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
    final ducked = music.volumeKeyframes!.where(
      (kf) => kf.volume < 0.5 && kf.time >= 3.0 - 0.15 && kf.time <= 7.0 + 0.30,
    );
    expect(
      ducked.isNotEmpty,
      isTrue,
      reason: 'Expected a dipped keyframe around the voiceover window',
    );

    // Closing keyframe must return to normal.
    final last = music.volumeKeyframes!.last;
    expect(last.volume, closeTo(1.0, 1e-9));
    expect(last.time, closeTo(10.0, 1e-9));
  });

  // ── DUCK-4: Original audio is NOT a foreground trigger (Phase 10-C Slice B)
  // 'original' static muting is owned by applyAudioCompositionPolicy, not here.
  test(
    'DUCK-4 original audio is not a foreground trigger — music is unchanged',
    () {
      final tracks = [
        _track(id: 'music1', role: 'music', start: 0.0, duration: 8.0),
        _track(id: 'orig1', role: 'original', start: 2.0, duration: 3.0),
      ];
      final result = _engine.apply(tracks, config: _cfg);
      final music = result.firstWhere((t) => t.trackId == 'music1');
      // No voiceover present → engine produces no foreground intervals →
      // music receives no ducking keyframes.
      expect(
        music.volumeKeyframes,
        isNull,
        reason:
            'original is not a foreground trigger; music must not be ducked',
      );
      // Original track itself passes through unchanged.
      final orig = result.firstWhere((t) => t.trackId == 'orig1');
      expect(orig.volumeKeyframes, isNull);
    },
  );

  // ── DUCK-5: Non-overlapping foreground does not duck music ────────────────
  test('DUCK-5 non-overlapping foreground does not duck music', () {
    // Music: 0–5s.  Voiceover: 6–9s.  No overlap.
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 5.0),
      _track(id: 'vo1', role: 'voiceover', start: 6.0, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final music = result.firstWhere((t) => t.trackId == 'music1');
    expect(
      music.volumeKeyframes,
      isNull,
      reason: 'No overlap → no keyframes expected',
    );
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
    expect(
      dipCount,
      1,
      reason: 'Merged intervals should produce a single duck envelope',
    );
  });

  // ── DUCK-7: Near-adjacent intervals merged by threshold ───────────────────
  test(
    'DUCK-7 near-adjacent foreground intervals are merged by gap threshold',
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
      expect(
        dipEntries,
        1,
        reason: 'Near-adjacent intervals should merge into one duck',
      );
    },
  );

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

  // ── DUCK-10: SFX ducks under voiceover (Phase 10-C Slice B) ──────────────
  test('DUCK-10 sfx ducks under voiceover', () {
    final sfxTrack = _track(id: 'sfx1', role: 'sfx', start: 0.0, duration: 5.0);
    final tracks = [
      sfxTrack,
      _track(id: 'vo1', role: 'voiceover', start: 1.0, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final sfx = result.firstWhere((t) => t.trackId == 'sfx1');
    // SFX overlaps with voiceover: ducking keyframes must be generated.
    expect(
      sfx.volumeKeyframes,
      isNotNull,
      reason: 'sfx is a known Added role and must duck under VO',
    );
    expect(sfx.volumeKeyframes!.any((kf) => kf.volume < 0.5), isTrue);
  });

  // ── DUCK-11: Existing volumeKeyframes on music track preserved ─────────────
  test(
    'DUCK-11 music track with existing volumeKeyframes is not overwritten',
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
      expect(
        identical(music, original),
        isTrue,
        reason: 'Pre-authored keyframes must not be replaced',
      );
    },
  );

  // ── DUCK-12: Engine does not mutate input list or track objects ────────────
  test('DUCK-12 engine does not mutate input list or track objects', () {
    final music = _track(
      id: 'music1',
      role: 'music',
      start: 0.0,
      duration: 10.0,
    );
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
    final minVolume = music.volumeKeyframes!
        .map((kf) => kf.volume)
        .reduce((a, b) => a < b ? a : b);
    expect(minVolume, closeTo(0.10, 1e-9));
  });

  // ── DUCK-14: Custom attack / release reflected in keyframe timing ──────────
  test(
    'DUCK-14 custom attack and release durations appear in keyframe times',
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
    },
  );

  // ── DUCK-15: Output is serializable through VGAudioSidecarPlan ────────────
  test('DUCK-15 output is serializable through VGAudioSidecarPlan.toMap()', () {
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 10.0),
      _track(id: 'vo1', role: 'voiceover', start: 2.0, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final plan = VGAudioSidecarPlan(tracks: result);
    final map = plan.toMap();

    // Round-trip.
    final restored = VGAudioSidecarPlan.fromMap(map.cast<Object?, Object?>());
    expect(restored, isNotNull);
    expect(restored!.tracks.length, 2);

    final restoredMusic = restored.tracks.firstWhere(
      (t) => t.trackId == 'music1',
    );
    expect(restoredMusic.volumeKeyframes, isNotNull);
    expect(restoredMusic.volumeKeyframes!.isNotEmpty, isTrue);
  });

  // ── DUCK-16: Null-role tracks pass through unchanged ──────────────────────
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

  // ── DUCK-18: voiceover is never a ducking target ──────────────────────────
  test('DUCK-18 voiceover track is never modified by the engine', () {
    final vo = _track(id: 'vo1', role: 'voiceover', start: 2.0, duration: 4.0);
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 10.0),
      vo,
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final resultVo = result.firstWhere((t) => t.trackId == 'vo1');
    // Voiceover track object must be the identical input object.
    expect(
      identical(resultVo, vo),
      isTrue,
      reason: 'voiceover must never be a ducking target',
    );
  });

  // ── DUCK-19: original track is never a ducking target ─────────────────────
  test('DUCK-19 original track passes through the engine unchanged', () {
    final orig = _track(
      id: 'orig1',
      role: 'original',
      start: 0.0,
      duration: 5.0,
    );
    final tracks = [
      orig,
      _track(id: 'vo1', role: 'voiceover', start: 1.0, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final resultOrig = result.firstWhere((t) => t.trackId == 'orig1');
    expect(
      identical(resultOrig, orig),
      isTrue,
      reason: 'original must never be a ducking target',
    );
  });

  // ── DUCK-20: unknown role passes through unchanged ────────────────────────
  test(
    'DUCK-20 unknown role string passes through unchanged and is not ducked',
    () {
      final unknown = _track(
        id: 'unknown1',
        role: 'imported_audio',
        start: 0.0,
        duration: 5.0,
      );
      final tracks = [
        unknown,
        _track(id: 'vo1', role: 'voiceover', start: 1.0, duration: 3.0),
      ];
      final result = _engine.apply(tracks, config: _cfg);
      final resultUnknown = result.firstWhere((t) => t.trackId == 'unknown1');
      expect(
        identical(resultUnknown, unknown),
        isTrue,
        reason: 'unknown role must pass through unchanged and not be ducked',
      );
    },
  );

  // ── DUCK-21: sfx with existing keyframes is preserved ─────────────────────
  test('DUCK-21 sfx track with existing keyframes is not overwritten', () {
    final existingKfs = [
      const VGAudioVolumeKeyframe(time: 0.0, volume: 0.6),
      const VGAudioVolumeKeyframe(time: 3.0, volume: 0.6),
    ];
    final sfx = _track(
      id: 'sfx1',
      role: 'sfx',
      start: 0.0,
      duration: 5.0,
      volumeKeyframes: existingKfs,
    );
    final tracks = [
      sfx,
      _track(id: 'vo1', role: 'voiceover', start: 1.0, duration: 3.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final resultSfx = result.firstWhere((t) => t.trackId == 'sfx1');
    // Same object: pre-authored keyframes must not be replaced.
    expect(
      identical(resultSfx, sfx),
      isTrue,
      reason:
          'sfx track with pre-authored keyframes must not receive generated ducking',
    );
  });

  // ── DUCK-22: track order and IDs are preserved ────────────────────────────
  test('DUCK-22 track ordering and IDs are preserved in output', () {
    final tracks = [
      _track(id: 'music1', role: 'music', start: 0.0, duration: 10.0),
      _track(id: 'vo1', role: 'voiceover', start: 2.0, duration: 4.0),
      _track(id: 'sfx1', role: 'sfx', start: 0.0, duration: 5.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    expect(result.length, 3);
    expect(result[0].trackId, 'music1');
    expect(result[1].trackId, 'vo1');
    expect(result[2].trackId, 'sfx1');
  });

  // ── DUCK-23: ducked music preserves non-unity mixGain ──────────────────────
  test('DUCK-23 ducked music preserves non-unity mixGain', () {
    final tracks = [
      _track(
        id: 'music1',
        role: 'music',
        start: 0.0,
        duration: 10.0,
        mixGain: 0.18,
      ),
      _track(id: 'vo1', role: 'voiceover', start: 3.0, duration: 4.0),
    ];
    final result = _engine.apply(tracks, config: _cfg);
    final music = result.firstWhere((t) => t.trackId == 'music1');
    expect(music.volumeKeyframes, isNotNull);
    expect(music.volumeKeyframes!.isNotEmpty, isTrue);
    expect(music.mixGain, closeTo(0.18, 1e-9));
  });

  // ── DUCK-24: Music with fadeIn/fadeOut and no VO gets fade-only absolute keyframes ──
  test(
    'DUCK-24 music with fadeIn/fadeOut and no VO gets fade-only absolute keyframes',
    () {
      final track = VGAudioSidecarTrack(
        trackId: 'music1',
        url: '/tmp/music1.m4a',
        startTime: 2.0,
        duration: 10.0,
        volume: 0.8,
        role: 'music',
        fadeInSeconds: 1.0,
        fadeOutSeconds: 2.0,
      );
      final result = _engine.apply([track], config: _cfg);
      expect(result.length, 1);
      final music = result.first;
      expect(music.volumeKeyframes, isNotNull);
      expect(music.volumeKeyframes!.length, equals(4));

      // Ramps:
      // start (2.0) -> volume 0.0
      // fadeInEnd (2.0 + 1.0 = 3.0) -> volume 0.8
      // fadeOutStart (12.0 - 2.0 = 10.0) -> volume 0.8
      // end (12.0) -> volume 0.0
      expect(music.volumeKeyframes![0].time, closeTo(2.0, 1e-6));
      expect(music.volumeKeyframes![0].volume, closeTo(0.0, 1e-6));

      expect(music.volumeKeyframes![1].time, closeTo(3.0, 1e-6));
      expect(music.volumeKeyframes![1].volume, closeTo(0.8, 1e-6));

      expect(music.volumeKeyframes![2].time, closeTo(10.0, 1e-6));
      expect(music.volumeKeyframes![2].volume, closeTo(0.8, 1e-6));

      expect(music.volumeKeyframes![3].time, closeTo(12.0, 1e-6));
      expect(music.volumeKeyframes![3].volume, closeTo(0.0, 1e-6));
    },
  );

  // ── DUCK-25: Voiceover with fadeIn/fadeOut gets fade-only keyframes and is not ducked ──
  test(
    'DUCK-25 voiceover with fadeIn/fadeOut gets fade-only keyframes and is not ducked',
    () {
      final vo = VGAudioSidecarTrack(
        trackId: 'vo1',
        url: '/tmp/vo1.m4a',
        startTime: 0.0,
        duration: 5.0,
        volume: 0.9,
        role: 'voiceover',
        fadeInSeconds: 1.0,
        fadeOutSeconds: 1.0,
      );
      // Even with itself or other VO tracks, VO is never ducked.
      final result = _engine.apply([vo], config: _cfg);
      expect(result.length, 1);
      final resultVo = result.first;
      expect(resultVo.volumeKeyframes, isNotNull);
      expect(resultVo.volumeKeyframes!.length, equals(4));

      // Ramps:
      // start (0.0) -> 0.0
      // fadeInEnd (1.0) -> 0.9
      // fadeOutStart (4.0) -> 0.9
      // end (5.0) -> 0.0
      expect(resultVo.volumeKeyframes![0].time, closeTo(0.0, 1e-6));
      expect(resultVo.volumeKeyframes![0].volume, closeTo(0.0, 1e-6));

      expect(resultVo.volumeKeyframes![1].time, closeTo(1.0, 1e-6));
      expect(resultVo.volumeKeyframes![1].volume, closeTo(0.9, 1e-6));

      expect(resultVo.volumeKeyframes![2].time, closeTo(4.0, 1e-6));
      expect(resultVo.volumeKeyframes![2].volume, closeTo(0.9, 1e-6));

      expect(resultVo.volumeKeyframes![3].time, closeTo(5.0, 1e-6));
      expect(resultVo.volumeKeyframes![3].volume, closeTo(0.0, 1e-6));
    },
  );

  // ── DUCK-26: Music/sfx with existing non-empty volumeKeyframes plus fade fields and overlapping VO are returned unchanged/identical ──
  test(
    'DUCK-26 music/sfx with existing keyframes, fades, and overlapping VO are returned identical',
    () {
      final existingKfs = [const VGAudioVolumeKeyframe(time: 1.0, volume: 0.7)];

      // 1. Music track case
      final music = VGAudioSidecarTrack(
        trackId: 'music1',
        url: '/tmp/music1.m4a',
        startTime: 0.0,
        duration: 10.0,
        volume: 0.8,
        role: 'music',
        fadeInSeconds: 1.0,
        fadeOutSeconds: 1.0,
        volumeKeyframes: existingKfs,
      );

      // 2. SFX track case
      final sfx = VGAudioSidecarTrack(
        trackId: 'sfx1',
        url: '/tmp/sfx1.m4a',
        startTime: 0.0,
        duration: 10.0,
        volume: 0.8,
        role: 'sfx',
        fadeInSeconds: 1.0,
        fadeOutSeconds: 1.0,
        volumeKeyframes: existingKfs,
      );

      final vo = VGAudioSidecarTrack(
        trackId: 'vo1',
        url: '/tmp/vo1.m4a',
        startTime: 3.0,
        duration: 2.0,
        role: 'voiceover',
      );

      final result = _engine.apply([music, sfx, vo], config: _cfg);

      final resultMusic = result.firstWhere((t) => t.trackId == 'music1');
      expect(identical(resultMusic, music), isTrue);

      final resultSfx = result.firstWhere((t) => t.trackId == 'sfx1');
      expect(identical(resultSfx, sfx), isTrue);
    },
  );

  // ── DUCK-27: Music volume 0.5 + ducking + fade uses normalized fade scale (no squaring at sustain) ──
  test(
    'DUCK-27 music volume 0.5 + ducking + fade uses normalized fade scale, not squared volume',
    () {
      final music = VGAudioSidecarTrack(
        trackId: 'music1',
        url: '/tmp/music1.m4a',
        startTime: 0.0,
        duration: 10.0,
        volume: 0.5,
        role: 'music',
        fadeInSeconds: 2.0,
        fadeOutSeconds: 2.0,
      );
      final vo = VGAudioSidecarTrack(
        trackId: 'vo1',
        url: '/tmp/vo1.m4a',
        startTime: 4.0,
        duration: 2.0,
        role: 'voiceover',
      );
      // Config: duckVolume = 0.25, attack = 0.15, release = 0.30
      final result = _engine.apply([music, vo], config: _cfg);
      final resultMusic = result.firstWhere((t) => t.trackId == 'music1');
      expect(resultMusic.volumeKeyframes, isNotNull);

      // Let's verify the volumes at key times using linear interpolation:
      final kfs = resultMusic.volumeKeyframes!;

      double valAt(double t) {
        if (t <= kfs.first.time) return kfs.first.volume;
        if (t >= kfs.last.time) return kfs.last.volume;
        for (var i = 0; i < kfs.length - 1; i++) {
          if (t >= kfs[i].time && t <= kfs[i + 1].time) {
            final frac = (t - kfs[i].time) / (kfs[i + 1].time - kfs[i].time);
            return kfs[i].volume + frac * (kfs[i + 1].volume - kfs[i].volume);
          }
        }
        return 1.0;
      }

      // At t = 0.0, fade is 0.0 -> volume should be 0.0
      expect(valAt(0.0), closeTo(0.0, 1e-5));

      // At t = 2.0 (sustain region of fade, fade scale is 1.0). Ducking has not started.
      // Absolute volume should be exactly track.volume = 0.5. (Not 0.25!).
      expect(valAt(2.0), closeTo(0.5, 1e-5));

      // At t = 3.85 (ducking attack starts, fade scale is 1.0).
      expect(valAt(3.85), closeTo(0.5, 1e-5));

      // At t = 4.0 (ducking dip reached, fade scale is 1.0).
      // Absolute volume should be duckVolume = 0.25. (Not 0.25 * 0.5 = 0.125!).
      expect(valAt(4.0), closeTo(0.25, 1e-5));

      // At t = 6.0 (ducking dip ends, fade scale is 1.0).
      expect(valAt(6.0), closeTo(0.25, 1e-5));

      // At t = 6.30 (ducking release ends, fade scale is 1.0).
      expect(valAt(6.30), closeTo(0.5, 1e-5));

      // At t = 8.0 (sustain end).
      expect(valAt(8.0), closeTo(0.5, 1e-5));

      // At t = 10.0, fade ends -> volume should be 0.0
      expect(valAt(10.0), closeTo(0.0, 1e-5));
    },
  );

  // ── DUCK-28: Overlapping fades scale proportionally to fit exactly ──
  test(
    'DUCK-28 overlapping fades scale proportionally with no midpoint product',
    () {
      final music = VGAudioSidecarTrack(
        trackId: 'music1',
        url: '/tmp/music1.m4a',
        startTime: 0.0,
        duration: 4.0,
        volume: 0.8,
        role: 'music',
        fadeInSeconds: 4.0,
        fadeOutSeconds: 4.0,
      );
      final result = _engine.apply([music], config: _cfg);
      final resultMusic = result.first;
      expect(resultMusic.volumeKeyframes, isNotNull);

      // Proportional scaling: fadeIn + fadeOut = 8.0 > 4.0 duration.
      // scale = 4.0 / 8.0 = 0.5.
      // effectiveFadeIn = 2.0, effectiveFadeOut = 2.0.
      // Breakpoints:
      // start (0.0) -> 0.0
      // fadeInEnd (2.0) -> 0.8
      // fadeOutStart (4.0 - 2.0 = 2.0) -> 0.8 (deduped or merged)
      // end (4.0) -> 0.0
      //
      // Let's verify the keyframes:
      final kfs = resultMusic.volumeKeyframes!;
      expect(kfs.length, equals(3)); // 0.0 -> 0.0, 2.0 -> 0.8, 4.0 -> 0.0

      expect(kfs[0].time, closeTo(0.0, 1e-6));
      expect(kfs[0].volume, closeTo(0.0, 1e-6));

      expect(kfs[1].time, closeTo(2.0, 1e-6));
      expect(kfs[1].volume, closeTo(0.8, 1e-6));

      expect(kfs[2].time, closeTo(4.0, 1e-6));
      expect(kfs[2].volume, closeTo(0.0, 1e-6));
    },
  );
}
